# FlySim — A Plain-English Guide

*What it is, what it does, and how to play with it — no science degree required.*

---

## 1. The one-sentence version

We put a **real fruit fly's brain inside your computer** and let you poke it and
watch it react — live.

That's not a figure of speech. Scientists spent years with electron microscopes
tracing **every single neuron (brain cell) and every wire between them** in an
actual fruit fly. There are about **139,000 neurons** and **17 million
connections**. FlySim loads that exact wiring map and makes each neuron behave
the way a real one does: it builds up a little electrical charge, and when it
gets enough, it "fires" a pulse to everything it's wired to. Do that 1,000 times
a second for all 139,000 cells and you get a living little brain simulation.

---

## 2. What we actually built

Think of it like a **player piano**, but for a brain:

- The **connectome** (the wiring map) is the piano roll — it never changes; it's
  the fixed structure of this particular fly.
- The **simulator** is the piano mechanism — it "plays" the neurons by the rules
  of biology, one millisecond at a time.
- **You** are the person pressing keys — you feed in tastes (sugar, water,
  bitter) and watch the brain respond.

We got it running three ways, each producing the *exact same answer*:
- on the **CPU** (your Mac's main processor),
- on the **GPU** (the graphics chip — much faster),
- and in a clever "**only do the work that matters**" mode that makes the whole
  brain run **faster than a real fly's brain actually runs** (about 3.7× faster).

---

## 3. The window, top to bottom

When you open the app you'll see one panel (styled to look like Apple's Logic
Pro music studio). Here's every part.

### The top bar (the "transport," like a tape deck)

| Control | What it does |
|---|---|
| **RUN / STOP** | Starts or pauses the brain. While running, time flows and neurons fire. |
| **RESET** | Wipes the brain back to a calm resting state (forgets the last few seconds of activity). |
| **CPU / GPU·Metal** | Which chip does the math. GPU is faster; the answer is identical. |
| **Speed (1× … MAX)** | How fast time runs. **1× = real fly speed.** MAX = "fast-forward," as fast as the computer can go. |
| **60/90/120 Hz** | How often the *picture* refreshes (like a screen's frame rate). Doesn't change the brain, just the smoothness of what you see. |
| **⚙ Settings** | Opens the settings page (the remote-control port — see §7). |

### The left panel — STIMULUS (what you feed the fly)

Three big illuminated buttons. These are the fly's **sense of taste**:

- **SUGAR** 🟠 — "yummy food!" In a real fly, tasting sugar makes it stick out
  its tongue to eat. This is the main thing FlySim demonstrates.
- **WATER** 🔵 — "something drinkable." Uses many of the same taste cells as sugar.
- **BITTER** 🔴 — "yuck, poison!" Tells the fly *not* to eat.

Press a button to "put that flavor on the fly's tongue." The **CLAMP RATE
slider** below sets how *strong* the taste is (how hard those taste cells are
driven, in pulses per second). 150 is a good strong taste.

### The middle — POPULATION ACTIVITY (the big colorful scrolling graph)

This is the **"brain lighting up" view** — the star of the show.

- Picture the 139,000 neurons squished into **128 horizontal stripes**, top to
  bottom. Each stripe is a different region of the brain.
- Time scrolls **left → right**: the right edge is "right now," and older
  activity slides off to the left (like a heart-rate monitor or a seismograph).
- **Color = how busy that region is.** Dark/black = quiet, asleep. Then it
  climbs purple → orange → bright yellow as cells fire harder.

So when you press **SUGAR**, you'll literally see a band light up and a wave of
color spread through the brain as the "I taste sugar!" signal travels from the
tongue, through the brain, to the muscles. **That traveling wave is a thought,
basically.**

### The bottom — MOTOR OUTPUT (what the fly decides to *do*)

This is the brain's "answer." Two big readouts:

- **MN9 FIRING RATE** 🟢 — MN9 is the specific brain cell that drives the fly's
  **proboscis** (its tongue/mouthparts). The number and green bar show how hard
  that cell is firing, in Hz (pulses per second). **High = the fly is trying to
  eat.**
- **PROBOSCIS EXTENSION** 🟠 — we translate that firing into an actual motion:
  the angle the tongue sticks out, 0° (retracted) to ~42° (fully extended,
  chowing down).

Two small bars on the right are "tap points" deeper in the circuit:
- **sugar in** — how loud the taste signal is going *in*.
- **feeding interneurons** — the relay cells in the middle of the chain. Watching
  these light up *between* sugar-in and MN9-out shows the signal actually
  traveling through the brain, not teleporting.

---

## 4. Try it yourself (60-second tour)

1. Press **RUN**. The activity graph starts scrolling; everything's calm (mostly dark).
2. Click **SUGAR**. Watch the graph light up, the **MN9** meter jump, and
   **PROBOSCIS EXTENSION** climb toward 42°. *The fly just decided to eat.*
3. Now also click **BITTER** while sugar is on. In this real connectome the
   bitter "stop!" signal pushes back on the feeding circuit — a tug-of-war you
   can watch in the meters.
4. Click the buttons off, hit **RESET**, and it settles back to calm.
5. Flip **GPU·Metal** and set speed to **MAX** — same behavior, but now the whole
   brain is running several times faster than a real fly. The "steps/sec" and
   "× realtime" numbers on the status line show how fast.

That's the whole loop: **taste in → brain processes → tongue moves out.** Exactly
what a real fly does, running on your laptop.

---

## 5. What the speed/×real-time numbers mean

The brain advances in **1-millisecond ticks** (1,000 ticks = 1 second of fly
life). The status line shows **steps/sec**:

- **1,000 steps/sec = 1× real-time** — the sim keeps pace with a living fly.
- We hit **~3,760 steps/sec on the GPU = 3.76× real-time** — the simulated brain
  runs almost four times faster than the real thing.

The trick: at any instant only ~2-3% of neurons are actually firing, so instead
of recalculating all 17 million connections every tick, we only follow the ones
coming from cells that *just* fired. Same answer, far less work.

---

## 6. The honest limits (what it is NOT)

- **It's a reflex, not a pet.** It reacts to what you feed it. It does **not
  learn, remember, or have feelings** — there's no mechanism for that in this
  model, by design.
- **It's the brain only — no body below the neck.** A fly's walking and flying
  muscles are controlled by the *nerve cord* (like a spinal cord), which isn't in
  this dataset. So FlySim does feeding/tasting/grooming-type behaviors, not
  walking around.
- **It's one snapshot of one fly.** Real brains vary and adapt; this is a fixed
  wiring diagram.

None of that makes it less amazing — it correctly predicts *which cells light up
and which actions fire* from a stimulus, which is exactly what the published
science validated.

---

## 7. The "remote control" (for the curious / AI folks)

FlySim has a built-in control server so other programs — including an AI
assistant — can **press the buttons and read the meters automatically**, without
touching the mouse. It listens on your own computer only (`127.0.0.1:7777`).

Open a Terminal while the app runs and try:

```
curl 127.0.0.1:7777/data            # everything the brain is doing right now
curl -XPOST 127.0.0.1:7777/tool/run # press RUN
curl -XPOST 127.0.0.1:7777/tool/clamp -d '{"modality":"sugar","hz":150}'  # taste sugar
curl -N 127.0.0.1:7777/stream?hz=60 # live feed of the readouts
```

`curl 127.0.0.1:7777/tools` lists every available command. You can change the
port in **⚙ Settings** if 7777 is busy. The idea: you could let an AI "drive" the
fly — feed it tastes, watch what fires, and reason about the result.

---

## 8. What could be added next

- **More senses:** smell, touch (antennae), and vision are all in the wiring map —
  we just haven't wired their buttons up yet.
- **A 3D fly:** drive an animated fly head so the tongue physically extends on
  screen when MN9 fires, and re-trigger taste when the tongue touches the food
  (closing the loop through a virtual world).
- **Grooming:** touch an antenna → the fly sweeps it with a leg.
- **More speed:** there's still headroom to make it run even faster than 3.7×.
- **The body (big project):** combine with a brain+nerve-cord dataset to attempt
  walking/flight — that's an open research frontier, not just a coding task.

---

*FlySim · educational project · (c) 2026 Epromfoundry, Inc. The fly connectome is
courtesy of the FlyWire project (Dorkenwald et al. & Schlegel et al., Nature 2024).*
