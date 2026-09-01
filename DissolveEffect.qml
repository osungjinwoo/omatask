import QtQuick
import QtQuick.Particles
import qs.Commons

// A short dust burst covering `targetItem`'s area — real QtQuick.Particles,
// not a CSS-style fake. Not glyph-shaped (that would need grabbing the row
// to an image and masking the emitter against it, which is fragile without
// a visual feedback loop to tune it against); this scatters from the row's
// bounding area instead, tinted per kind. Call trigger(), hide the real row
// alongside it, and listen for finished() to actually remove the data.
Item {
  id: root

  property Item targetItem: null
  property color tint: Color.accent

  signal finished()

  anchors.fill: targetItem
  visible: false
  z: 50

  function trigger() {
    root.visible = true
    emitter.burst(110)
    stopTimer.restart()
  }

  Timer {
    id: stopTimer
    interval: 750
    onTriggered: { root.visible = false; root.finished() }
  }

  ParticleSystem { id: system; anchors.fill: parent; running: root.visible }

  ImageParticle {
    system: system
    // No custom source: the default particle sprite (a soft round dot) is
    // the well-tested path here, rather than risking a data-URI image load
    // that may or may not resolve depending on which image plugins exist.
    color: root.tint
    colorVariation: 0.15
    alpha: 1.0
  }

  Emitter {
    id: emitter
    system: system
    anchors.fill: parent
    shape: EllipseShape {}
    emitRate: 0
    lifeSpan: 700
    lifeSpanVariation: 150
    size: 9
    sizeVariation: 3
    endSize: 2
    velocity: AngleDirection { angle: 270; angleVariation: 60; magnitude: 55; magnitudeVariation: 35 }
    acceleration: PointDirection { y: -22; yVariation: 10 }
  }
}
