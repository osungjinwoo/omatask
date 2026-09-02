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


def check_owned_private(fd, label):
    # Ownership alone isn't enough: a directory the current user owns but
    # left group/other-writable lets any other local user rename, delete or
    # swap entries inside it (including a file we're about to trust) —
    # exactly the tampering the O_NOFOLLOW/dir_fd walk elsewhere in this
    # file exists to defend against. Reject write access for anyone else at
    # every step, not just the leaf state dir.
    st = os.fstat(fd)
    if st.st_uid != os.getuid():
        os.close(fd)
        raise SystemExit("%s not owned by the current user" % label)
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        os.close(fd)
        raise SystemExit("%s is writable by other users (mode %o)" % (label, stat.S_IMODE(st.st_mode)))


def open_dir_step(parent_fd, name, create):
    # One hop of the walk below: open `name` relative to the already-held
    # `parent_fd`, never by a standalone path. O_NOFOLLOW rejects a symlink
    # at this exact component; O_NONBLOCK keeps a FIFO substitution from
    # hanging the open() call.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        fd = os.open(name, flags, dir_fd=parent_fd)
    except FileNotFoundError:
        if not create:
            raise
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
        fd = os.open(name, flags, dir_fd=parent_fd)
    check_owned_private(fd, repr(name))
    return fd


def open_state_dir(state_dir):
    # Anchor at the user's own home directory and open every path component
    # below it (.local, state, omarchy, this plugin's own state dir) one hop
    # at a time, relative to the previously held directory fd. A single
    # O_NOFOLLOW open() of the full path (the old approach, plus a separate
    # path-based os.makedirs() for its parent) only protects the *final*
    # component — if another local process had swapped an ancestor like
    # ~/.local/state for a symlink before this ran, the kernel would still
    # happily resolve through it on the way to the leaf. Walking fd-by-fd
    # with O_NOFOLLOW and an ownership check at every step protects every
    # ancestor, not just the leaf.
    home = os.path.expanduser("~")
    rel = os.path.relpath(os.path.normpath(state_dir), home)
    if rel == os.pardir or rel.startswith(os.pardir + os.sep) or os.path.isabs(rel):
        raise SystemExit("state dir must live under the home directory")
    parts = [p for p in rel.split(os.sep) if p and p != os.curdir]

    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    check_owned_private(fd, "home directory")
    for part in parts:
        next_fd = open_dir_step(fd, part, create=True)
        os.close(fd)
        fd = next_fd
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
    # Only remove the original entry if it still resolves to the exact
    # inode we validated and hardlinked above. Unlinking by name alone here
    # (the old approach) could delete a *different* file if `name` was
    # swapped again in the window between the hardlink and this unlink —
    # re-lstat relative to the held dir fd and compare device/inode first.
    try:
        st_name = os.lstat(name, dir_fd=dirfd)
    except OSError:
        return
    st_fd = os.fstat(fd)
    if st_name.st_dev == st_fd.st_dev and st_name.st_ino == st_fd.st_ino:
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
            # The name is a symlink — never follow it. We never opened the
            # target so there's no fd/inode to quarantine by, but still
            # re-check via lstat before unlinking: only remove the entry if
            # it's still the symlink we just failed to open, not whatever
            # may have been swapped in since.
            try:
                st = os.lstat(name, dir_fd=dirfd)
                if stat.S_ISLNK(st.st_mode):
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

    try:
        dirfd = open_state_dir(state_dir)
    except (OSError, SystemExit) as e:
        print("statehelper: %s" % e, file=sys.stderr)
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
