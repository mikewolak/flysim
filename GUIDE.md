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
| **⚙ Settings** | Opens the settings page (the remote-control port — see §8). |

### Two tabs: 🧠 Brain and ✈ Flight

The top has a **Brain / Flight** switch. **Brain** is the 2D view below (senses
in, brain lighting up, tongue out). **Flight** is a first-person 3D view where
the fly *flies itself* to food using its real navigation neurons — see §6.

### The left panel — STIMULUS (the fly's eight senses)

Eight illuminated buttons — every sense that's tagged in the real connectome:

- **SUGAR** 🟠 / **WATER** 🔵 / **BITTER** 🔴 — **taste.** Sugar = "yummy, eat!"
  (tongue out), water = drinkable, bitter = "yuck" (aversive — the fly rejects it).
- **SMELL** — **olfactory** (antennae). Drives the search: the fly climbs an odor
  gradient to find food.
- **TOUCH** — **mechanosensory.** The fly startles.
- **HEAT** / **HUMIDITY** — **thermo / hygrosensory.** The fly recoils from heat.
- **LIGHT** — **vision** (photoreceptors). The fly buzzes its wings.

Each sense produces a **visible reaction** on the animated fly. Press a button to
drive that sense; the **CLAMP RATE slider** sets how strong it is (pulses per
second). 150 is a good strong stimulus.

### The middle — POPULATION ACTIVITY (the big colorful scrolling graph)

This is the **"brain lighting up" view** — the star of the show.

- The 139,000 neurons are squished into **128 horizontal stripes**, and they're
  **ordered by job**: the **senses are at the bottom**, then the optic lobe, then
  the central brain, then the command and **motor neurons at the top**.
- Time scrolls **left → right**: the right edge is "right now," and older
  activity slides off to the left (like a heart-rate monitor or a seismograph).
- **Color = how busy that region is.** Dark/black = quiet. Then it climbs purple
  → orange → bright yellow as cells fire harder.
- **Hover any band** and a tooltip tells you what it is — e.g. *"optic lobe ·
  visual processing — 77,539 neurons (55.7%)."* (Yes: **over half the fly brain
  is vision.**)

Because it's ordered bottom-to-top by job, when you press **SUGAR** you see the
*bottom* (taste) band light up first, then a wave of color climb **upward** to
the motor band as the "I taste sugar!" signal travels from tongue to muscles.
**That upward traveling wave is a thought, basically.**

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
3. Try **SMELL** + **PLACE FOOD**: the fly smells the odor and **walks to it**,
   climbing the gradient, then sticks out its tongue once it arrives. Drag the
   food and it turns around and re-finds it.
4. Poke other senses: **LIGHT** buzzes its wings, **TOUCH** makes it startle,
   **HEAT** makes it recoil. Each sense lights its own band at the bottom of the
   activity graph.
5. Click the buttons off, hit **RESET**, and it settles back to calm.
6. Flip **GPU·Metal** and set speed to **MAX** — same behavior, several times
   faster than a real fly. The "steps/sec" / "× realtime" numbers show how fast.
7. Switch to the **✈ Flight** tab and watch the fly fly *itself* to food (§6).

That's the whole loop: **senses in → brain processes → action out.** Exactly what
a real fly does, running on your laptop.

> *A note on bitter:* in a real fly, bitter taste suppresses feeding. The exact
> inhibitory wiring for that isn't strong in this connectome subset, so FlySim is
> honest about it — bitter is shown as an **aversive** taste the fly rejects, not
> a fake "feeding off switch." The sugar→feeding→tongue chain, though, is real and
> measurable end to end.

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

## 6. The Flight view — the fly flies *itself*

Switch to the **✈ Flight** tab for a first-person 3D world: you're looking out of
the fly's eyes as it flies to a glowing food orb, dodging blue pillars. The point
is that **the brain is doing the flying** — it's not following a scripted path:

- **Finding food (vision + smell).** Where the food sits drives the fly's left vs.
  right eyes and antennae. The brain's real **steering neurons** (the "DNa" cluster
  — the fly's actual turn-command cells) read out stronger on one side and **bank
  the fly toward the food.**
- **Dodging pillars (escape).** A pillar that's close and dead-ahead "looms" — it
  stimulates the eyes on that side, and the brain's real **escape neurons** (the
  "DNp" cluster, including the famous *giant fiber*) fire and **veer the fly away.**
- A gyro (bottom-left) shows the fly's tilt; a minimap (top-right) shows where it
  is. The horizon banks into turns but stays upright — fruit flies don't cruise
  upside down.

So the steering you watch is genuine brain output: senses → real descending
command neurons → turn. (The wing *muscles* themselves live in the nerve cord,
which isn't in this dataset — see the next section — so we translate the brain's
steering command into the flight, the same honest way the tongue follows MN9.)

---

## 7. The honest limits (what it is NOT)

- **It's a reflex, not a pet.** It reacts to what you feed it. It does **not
  learn, remember, or have feelings** — there's no mechanism for that in this
  model, by design.
- **It's the brain only — no body below the neck.** A fly's walking and flying
  *muscles* are controlled by the *nerve cord* (like a spinal cord), which isn't
  in this dataset. The Flight view uses the brain's real **steering commands** to
  fly a stand-in body; it doesn't simulate the wing muscles themselves.
- **It's one snapshot of one fly.** Real brains vary and adapt; this is a fixed
  wiring diagram.

None of that makes it less amazing — it correctly predicts *which cells light up
and which actions fire* from a stimulus, which is exactly what the published
science validated.

---

## 8. The "remote control" (for the curious / AI folks)

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

## 9. What could be added next

Done since the first version: **all eight senses are wired up**, each with a
visible reaction; the activity strip is **ordered by brain region** with hover
labels; and the **3D Flight view** flies the fly with its real steering neurons.
Still on the list:

- **Learning / memory:** the mushroom-body circuitry is in the wiring map; adding
  plasticity would let it actually *learn* an odor, not just react.
- **Grooming & more motor programs:** touch an antenna → sweep it with a leg.
- **More speed:** there's still headroom to push past 3.7× real-time.
- **The body (big project):** combine with a brain+nerve-cord dataset to simulate
  the actual flight/walking muscles, not just the brain's command to them — an
  open research frontier, not just a coding task.

---

*FlySim · educational project · (c) 2026 Epromfoundry, Inc. The fly connectome is
courtesy of the FlyWire project (Dorkenwald et al. & Schlegel et al., Nature 2024).*
