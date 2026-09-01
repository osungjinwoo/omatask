#!/usr/bin/env python3
"""FD-safe load/save for omatask's private state files.

Invoked as a short-lived subprocess by Service.qml (never with
attacker-influenced argv: state_dir/name/cap all come from the plugin
itself). Exists because QML/JS has no syscall access, and path-based
checks (`stat` a path, then separately open/chmod/rm that same path) are
inherently TOCTOU-able — the file at a path can be swapped between the
check and the act. Everything here is anchored to a directory file
descriptor opened once with O_NOFOLLOW, and every filename lookup after
that is done relative to that fd (dir_fd=), so a swap of the directory
itself can't retarget us mid-operation. Symlinks for the state files
themselves are rejected outright (O_NOFOLLOW on the open, not a stat
check beforehand).

Protocol: `statehelper.py <state_dir> load|save <tasks.json|notes.json> <max_bytes>`
load writes validated bytes to stdout (empty if missing/invalid).
save reads new content from stdin and writes it atomically.
Exit code 0 means "trust stdout" (load) / "written" (save); anything
else means the caller must not trust whatever partial stdout exists.
"""
import errno
import os
import random
import stat
import sys
import time

ALLOWED_NAMES = ("tasks.json", "notes.json")
READ_CHUNK = 65536


def open_state_dir(path):
    # O_NONBLOCK matters here too: if the directory entry were ever a FIFO
    # instead of a directory, a blocking open() could hang this process
    # forever waiting for a reader/writer that will never come. O_DIRECTORY
    # would then fail fast with ENOTDIR anyway, but there's no reason to
    # rely on that ordering when O_NONBLOCK makes the open itself non-blocking.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        os.mkdir(path, 0o700)
        fd = os.open(path, flags)
    st = os.fstat(fd)
    if st.st_uid != os.getuid():
        os.close(fd)
        raise SystemExit("state dir not owned by current user")
    os.fchmod(fd, 0o700)
    return fd


def quarantine(dirfd, fd, name):
    # Hardlink the exact inode we already have open (via the /proc/self/fd
    # magic symlink) into a new name in the same directory, bypassing the
    # path entirely — so even if `name` has been swapped again since we
    # opened it, we preserve the actual bytes we validated against, not
    # whatever now happens to sit at that path.
    qname = "quarantine-%s-%d-%d" % (name, int(time.time()), os.getpid())
    try:
        os.link("/proc/self/fd/%d" % fd, qname, dst_dir_fd=dirfd, follow_symlinks=True)
    except OSError:
        pass
    try:
        os.unlink(name, dir_fd=dirfd)
    except OSError:
        pass


def load(dirfd, name, max_bytes):
    # O_NONBLOCK: if `name` was swapped for a FIFO, a blocking open() for
    # read would hang until something opens the other end for write —
    # a cheap DoS. Regular-file I/O is unaffected by O_NONBLOCK on Linux,
    # so this is free for the legitimate case and only changes behavior
    # for the attack case (fstat below then rejects the non-regular file).
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NOCTTY | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        fd = os.open(name, flags, dir_fd=dirfd)
    except FileNotFoundError:
        return b""
    except OSError as e:
        if e.errno == errno.ELOOP:
            # The name is a symlink — never follow it. Nothing to quarantine
            # by inode (we never opened the target), just drop the entry.
            try:
                os.unlink(name, dir_fd=dirfd)
            except OSError:
                pass
            return b""
        raise
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > max_bytes:
            quarantine(dirfd, fd, name)
            return b""
        data = bytearray()
        remaining = st.st_size
        while remaining > 0:
            chunk = os.read(fd, min(remaining, READ_CHUNK))
            if not chunk:
                break
            data += chunk
            remaining -= len(chunk)
            if len(data) > max_bytes:
                break
        return bytes(data)
    finally:
        os.close(fd)


def save(dirfd, name, data, max_bytes):
    if len(data) > max_bytes:
        raise SystemExit("payload exceeds max_bytes")
    tmp = None
    fd = None
    for _ in range(8):
        candidate = ".tmp-%s-%d-%d" % (name, os.getpid(), random.randrange(1 << 30))
        try:
            fd = os.open(
                candidate,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                0o600,
                dir_fd=dirfd,
            )
            tmp = candidate
            break
        except FileExistsError:
            continue
    if tmp is None:
        raise SystemExit("could not create temp file")
    try:
        written = 0
        view = memoryview(data)
        while written < len(data):
            n = os.write(fd, view[written:written + READ_CHUNK])
            if n <= 0:
                raise OSError("short write")
            written += n
        # Set the mode before the rename, not after: once a name is public
        # a separate later chmod-by-path would itself be racing a symlink
        # swap at that path. Permissions on a freshly-created, not-yet-
        # visible temp fd carry through the atomic rename below instead.
        os.fchmod(fd, 0o600)
        os.fsync(fd)
    finally:
        os.close(fd)
    # rename() replaces the directory entry at `name` directly — it does
    # not follow a symlink that might currently be sitting there — so this
    # is safe even if an attacker swapped `name` for a symlink in the
    # meantime.
    os.replace(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
    try:
        os.fsync(dirfd)
    except OSError:
        pass


def main():
    if len(sys.argv) != 5:
        sys.exit(2)
    state_dir, op, name, max_bytes_s = sys.argv[1:5]
    if name not in ALLOWED_NAMES or op not in ("load", "save"):
        sys.exit(2)
    try:
        max_bytes = int(max_bytes_s)
    except ValueError:
        sys.exit(2)

    os.makedirs(os.path.dirname(state_dir.rstrip("/")), exist_ok=True)
    try:
        dirfd = open_state_dir(state_dir)
    except OSError:
        sys.exit(1)
    try:
        if op == "load":
            data = load(dirfd, name, max_bytes)
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        else:
            data = sys.stdin.buffer.read(max_bytes + 1)
            save(dirfd, name, data, max_bytes)
    except (OSError, SystemExit) as e:
        print("statehelper: %s" % e, file=sys.stderr)
        sys.exit(1)
    finally:
        os.close(dirfd)


if __name__ == "__main__":
    main()
