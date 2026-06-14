#import "@preview/cetz:0.3.4"
#set page(width: auto, height: auto, margin: 12pt, fill: white)
#set text(font: "New Computer Modern", size: 9.5pt)

#let c-ext  = rgb("#eceff1")
#let c-gw   = rgb("#fdecea")
#let c-app  = rgb("#e8f0fe")
#let c-brk  = rgb("#fff3e0")
#let c-data = rgb("#e8f5e9")

#cetz.canvas(length: 1cm, {
  import cetz.draw: *

  // box centered at (x,y)
  let node(x, y, w, h, fill, body) = {
    rect((x - w/2, y - h/2), (x + w/2, y + h/2),
      radius: 3pt, fill: fill, stroke: 0.6pt + black, name: none)
    content((x, y), align(center, body))
  }
  let flow(a, b, lbl: none) = {
    line(a, b, mark: (end: ">", fill: black, scale: 0.8), stroke: 0.9pt)
    if lbl != none { content((a, 50%, b), anchor: "south", padding: 1.5pt, text(size: 8pt, lbl)) }
  }
  let dshed(a, b) = line(a, b, mark: (end: ">", fill: gray, scale: 0.8), stroke: (paint: gray, dash: "dashed", thickness: 0.9pt))

  // ---- columns ----
  let LX = 2.4      // main pipeline x
  let RX = 8.0      // data stores x

  // ---- sensors ----
  node(1.4, 12.6, 2.2, 0.95, c-ext, [WS101 \ #text(7.5pt)[button]])
  node(4.2, 12.6, 2.2, 0.95, c-ext, [WS202 \ #text(7.5pt)[PIR + light]])
  node(7.0, 12.6, 2.2, 0.95, c-ext, [WS302 \ #text(7.5pt)[sound level]])

  // ---- gateway ----
  node(4.2, 10.7, 3.4, 0.95, c-gw, [Milesight UG63 \ #text(7.5pt)[LoRaWAN gateway]])
  flow((1.4, 12.13), (4.0, 11.18))
  flow((4.2, 12.13), (4.2, 11.18))
  flow((7.0, 12.13), (4.4, 11.18), lbl: [LoRa (EU868)])

  // ---- mesh boundary ----
  rect((-0.4, -1.5), (10.2, 9.0), radius: 4pt,
    stroke: (paint: rgb("#3949ab"), dash: "dashed", thickness: 1pt))
  content((4.9, 8.55), text(size: 8.5pt, fill: rgb("#3949ab"))[
    iot-system namespace — Linkerd mesh: every link below is mTLS, deny-by-default
  ])

  // gateway -> bridge (crosses boundary)
  node(LX, 7.5, 3.6, 0.95, c-app, [chirpstack- \ gateway-bridge])
  dshed((4.2, 10.22), (LX, 8.0))
  content((6.6, 9.85), text(size: 8pt, fill: gray)[Semtech UDP \ NodePort 31700])

  // ---- main pipeline ----
  node(LX, 5.9, 3.6, 0.95, c-brk, [Mosquitto \ #text(7.5pt)[MQTT broker]])
  node(LX, 4.3, 3.6, 0.95, c-app, [ChirpStack \ #text(7.5pt)[LoRaWAN server]])
  node(LX, 2.6, 3.6, 0.95, c-app, [Node-RED \ #text(7.5pt)[MQTT -> SQL]])
  node(LX, 0.9, 3.6, 0.95, c-app, [iot-stat-reader \ #text(7.5pt)[FastAPI]])
  node(LX, -0.8, 3.6, 0.95, c-app, [iot-stat-frontend \ #text(7.5pt)[React dashboard]])

  // ---- data stores ----
  node(RX, 4.3, 2.8, 0.95, c-data, [Redis \ #text(7.5pt)[session cache]])
  node(RX, 1.7, 2.8, 0.95, c-data, [PostgreSQL \ #text(7.5pt)[device_uplinks]])

  // pipeline arrows
  flow((LX, 7.02), (LX, 6.38), lbl: [MQTT])
  flow((LX, 5.42), (LX, 4.78), lbl: [MQTT])
  flow((LX, 3.82), (LX, 3.08), lbl: [decoded uplink])
  flow((LX, 2.12), (RX - 1.4, 1.9))           // nodered -> postgres (INSERT)
  flow((RX - 1.4, 1.5), (LX, 0.95))           // postgres -> reader (SELECT)
  flow((LX, 0.42), (LX, -0.32), lbl: [/api])

  // store links
  flow((LX + 1.8, 4.3), (RX - 1.4, 4.3))      // chirpstack -> redis
  flow((LX + 1.6, 4.0), (RX - 1.4, 2.0))      // chirpstack -> postgres
})
