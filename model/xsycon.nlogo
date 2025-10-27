; ============================================================
; X-SYCON (passive) — v5.1
; - Pure passive: fields + gradient follow (no planning, no comms)
; - Reproducible: per-run seed & unique filenames
; - Deterministic stop: max-ticks OR DE quota
; - Beaconing: first-contact local boost (slider)
; - Urgency growth: base + alpha*urgency with caps
; - Dynamic hazards: mean-reverting toward target density
; - BehaviorSpace reporters: service/miss/means/energy/entropy/field stats
; ============================================================

extensions [array]

; ---------- REQUIRED SLIDERS / SWITCHES ----------
; diffDE (0–1)        decayDE (0–1)        leakDE (>=0)       de-cap (>=0)
; diffHZ (0–1)        decayHZ (0–1)
; s0                  alpha                u-growth           u-max
; kappa               beacon-bonus
; service-rate        service-radius
; wander-prob
; num-carriers
; p-new-DE            max-active-des
; miss-cutoff
; p-hazard-change     max-blocked-frac
; max-ticks           de-quota
; run-seed (int, -1=random)
; verbose? (switch; default false)

globals [
  run-id
  de-log-file
  run-summary-file
  file-opened?
  last-ttfr
  last-latency
  de-spawned
  de-served
  de-missed
  sum-energy
  sum-phi-mean
  sum-phi-var
  ticks-sampled
  bins-x
  bins-y
  bin-width-x
  bin-width-y
  cov-counts
  ttfr-sum ttfr-n
  latency-sum latency-n
  sim-initialized?
]


patches-own [
  phi-de
  phi-hz
  blocked?
]

breed [ carrierDrones carrierDrone ]
breed [ demands de ]

carrierDrones-own [
  step-energy
]

demands-own [
  t-create t-first t-done
  required-time remaining-time
  served?
  urgency
  beacon-on?
  missed?
]

; ---------- Helpers ----------
to-report normalized-seed
  ifelse is-number? run-seed
  [ report run-seed ]
  [ report read-from-string run-seed ]
end

; ===================== SETUP =====================
to setup
  clear-all

  ;; --- START TICKS BEFORE ANYTHING TOUCHES `ticks` ---
  reset-ticks

  set ttfr-sum 0 set ttfr-n 0
  set latency-sum 0 set latency-n 0


  ;; runtime flags
  set sim-initialized? true
  set file-opened? false

  ;; reproducible seed & run id
  if (is-number? run-seed or is-string? run-seed) [
    let s normalized-seed
    if s != -1 [ random-seed s ]
  ]
  set run-id (word "seed"
                   (ifelse-value ((is-number? run-seed or is-string? run-seed) and normalized-seed != -1)
                                 [ normalized-seed ] [ random 1000000 ])
                   "-t" precision (random-float 1.0) 6)

  ;; filenames
  set de-log-file      (word "de-log-" run-id ".csv")
  set run-summary-file (word "run-summary-" run-id ".csv")

  ;; fields & obstacles
  ask patches [
    set phi-de 0
    set phi-hz 0
    set blocked? false
  ]
  setup-obstacles-initial

  ;; counters & stats
  set de-spawned 0
  set de-served  0
  set de-missed  0
  set last-ttfr -1
  set last-latency -1
  set sum-energy 0
  set sum-phi-mean 0
  set sum-phi-var 0
  set ticks-sampled 0

  ;; coverage bins
  set bins-x 16
  set bins-y 16
  set bin-width-x (world-width / bins-x)
  set bin-width-y (world-height / bins-y)
  set cov-counts array:from-list n-values (bins-x * bins-y) [0]

  ;; warm-start DEs (these call initialize-de -> uses `ticks`, which is now started)
  repeat min list 2 max-active-des [ create-one-de ]

  ;; carriers
  create-carrierDrones num-carriers [
    set color blue
    set size 1.2
    set heading random 360
    set step-energy 0
    let placed? false
    while [ not placed? ] [
      setxy random-xcor random-ycor
      if (not [blocked?] of patch-here) and
         (not any? other carrierDrones in-radius 1.0) [
        set placed? true
      ]
    ]
  ]

  update-demands-urgency
  update-fields
  colorize-fields
  ;; NOTE: do NOT call reset-ticks again here
end

; ===================== MAIN LOOP =====================
to go
  if not sim-initialized? [ setup ]

  ;; deterministic stop for BehaviorSpace
  if ticks >= max-ticks [
  ;; Mark any still-active DEs as missed for accounting
  ask demands with [not served? and not missed?] [
    set missed? true
    set de-missed de-missed + 1
  ]
  finalize
  stop
]

  if (de-quota > 0) and ((de-served + de-missed) >= de-quota) [ finalize stop ]

  update-demands-urgency
  update-fields
  evolve-environment
  colorize-fields
  move-carriers
  service-and-complete
  sample-run-stats
  tick
end

; ===================== ENVIRONMENT =====================
to setup-obstacles-initial
  ;; start at ~60% of target so the mean-reverting process has headroom
  let target-fraction (max list 0 (min list 1 (max-blocked-frac * 0.6)))
  let target round (count patches * target-fraction)
  ask n-of target patches [
    set blocked? true
    set phi-hz 12
  ]
end


to evolve-environment
  ;; spawn new DEs if under active cap (Bernoulli per tick)
  if (count demands with [not served? and not missed?] < max-active-des)
    and (random-float 1 < p-new-DE) [
    create-one-de
  ]

  ;; mean-reverting flips toward max-blocked-frac
  if random-float 1 < p-hazard-change [
    let blk   count patches with [blocked?]
    let total count patches
    let frac  blk / total
    let gap   (max-blocked-frac - frac)
    let flips (max list 1 (round (abs gap * 0.05 * total)))  ;; ~5% of the gap per event

    ifelse gap > 0 [
      ;; need more blocked patches
      ask n-of flips patches with [not blocked?] [
        set blocked? true
        set phi-hz 12
      ]
    ] [
      ;; need fewer blocked patches
      ask n-of flips patches with [blocked?] [
        set blocked? false
        set phi-hz 0
      ]
    ]
  ]
end



; ===================== DEMANDS =====================
to create-one-de
  let p one-of patches with [ not blocked? and count demands-here = 0 ]
  if p != nobody [
    create-demands 1 [
      initialize-de
      move-to p
    ]
    set de-spawned de-spawned + 1
  ]
end

to initialize-de
  set color red
  set shape "circle"
  set size 2.0
  set t-create ticks
  set t-first -1
  set t-done  -1
  set required-time 60 + random 60
  set remaining-time required-time
  set served? false
  set urgency 0
  set beacon-on? false
  set missed? false
end

to update-demands-urgency
  ask demands with [ not served? and not missed? ] [
    set urgency min list u-max (urgency + u-growth)
  ]
end

; ===================== FIELDS =====================
to update-fields
  ;; proportional decay
  ask patches [
    set phi-de phi-de * (1 - decayDE)
    set phi-hz phi-hz * (1 - decayHZ)
  ]
  ;; absolute leak (demand only)
  if leakDE > 0 [
    ask patches [ set phi-de max list 0 (phi-de - leakDE) ]
  ]
  ;; hazards reseed
  ask patches with [ blocked? ] [ set phi-hz 12 ]

  ;; DE reseed: base + urgency + beacon bump, capped
  ask demands with [ not served? and not missed? ] [
    let s (s0 + alpha * urgency + (ifelse-value beacon-on? [beacon-bonus] [0]))
    ask patch-here [
      set phi-de phi-de + s
      if de-cap > 0 [ set phi-de min list phi-de de-cap ]
    ]
  ]

  ;; diffuse
  diffuse phi-de diffDE
  diffuse phi-hz diffHZ
end

; ===================== VIS =====================
to colorize-fields
  let m  max [phi-de] of patches
  let mn min [phi-de] of patches
  if m = mn [ set m mn + 1 ]
  ask patches [
    set pcolor ifelse-value blocked? [ grey - 3 ] [ scale-color red phi-de mn m ]
  ]
end

; ===================== MOTION (neighbors4, no diagonals) =====================
to move-carriers
  ask carrierDrones [
    bump-coverage-bin

    ;; separation
    if any? other carrierDrones in-radius 0.8 [
      rt one-of [-30 30]
      if not [blocked?] of patch-ahead 1 [
        fd 1
        set step-energy step-energy + 1
        set sum-energy sum-energy + 1
      ]
      stop
    ]

    let candidates neighbors4 with [ not blocked? ]
    ifelse any? candidates [
      let best max-one-of candidates [
        (phi-de - (kappa * phi-hz))
        - 0.15 * count carrierDrones-here
        + random-float 0.01
      ]
      face best
      if not [blocked?] of patch-ahead 1 [
        fd 1
        set step-energy step-energy + 1
        set sum-energy sum-energy + 1
      ]
    ] [
      if random-float 1 < wander-prob [
        rt one-of [-90 -45 45 90]
        if not [blocked?] of patch-ahead 1 [
          fd 1
          set step-energy step-energy + 1
          set sum-energy sum-energy + 1
        ]
      ]
    ]
  ]
end

to bump-coverage-bin
  let ix min list (bins-x - 1) max list 0 floor ((pxcor - min-pxcor) / bin-width-x)
  let iy min list (bins-y - 1) max list 0 floor ((pycor - min-pycor) / bin-width-y)
  let idx (iy * bins-x + ix)
  array:set cov-counts idx ( (array:item cov-counts idx) + 1 )
end

; ===================== SERVICE / LOGGING =====================
to service-and-complete
  ask demands with [ not served? and not missed? ] [
    let nearby carrierDrones in-radius service-radius

    if (t-first = -1) and any? nearby [
      set t-first ticks
      set beacon-on? true
      set color orange
    ]

    let work (count nearby) * service-rate
    if work > 0 [
      set remaining-time max list 0 (remaining-time - work)
    ]

    ;; ---------------- completion ----------------
    if remaining-time = 0 [
      set served? true
      set t-done ticks
      set color green

      ;; --- accumulate BEFORE die ---
      set ttfr-sum    ttfr-sum    + (t-first - t-create)
      set ttfr-n      ttfr-n      + 1
      set latency-sum latency-sum + (t-done  - t-create)
      set latency-n   latency-n   + 1
      ;; ------------------------------------------

      set last-ttfr    (t-first - t-create)
      set last-latency (t-done  - t-create)
      set de-served    de-served + 1
      log-de-row self 0
      die
    ]

    ;; ---------------- timeout → missed ----------------
    if (ticks - t-create) > miss-cutoff [
      set missed? true
      set served? true
      set t-done ticks
      set color violet

      ;; --- accumulate; TTFR only if first contact happened ---
      if t-first != -1 [
        set ttfr-sum ttfr-sum + (t-first - t-create)
        set ttfr-n   ttfr-n   + 1
      ]
      set latency-sum latency-sum + (t-done - t-create)
      set latency-n   latency-n   + 1
      ;; -------------------------------------------------------

      set last-ttfr    (ifelse-value (t-first = -1) [ -1 ] [ t-first - t-create ])
      set last-latency (t-done - t-create)
      set de-missed    de-missed + 1
      log-de-row self 1
      die
    ]
  ]
end


to ensure-log-open
  if not file-opened? [
    file-open de-log-file
    file-print "run_id,de_id,t_create,t_first,t_done,ttfr,latency,missed"
    set file-opened? true
  ]
end

to log-de-row [ d missed-flag ]
  ensure-log-open
  file-print (word run-id "," [who] of d "," [t-create] of d "," [t-first] of d "," [t-done] of d ","
                   (ifelse-value ([t-first] of d = -1) [ -1 ] [ ([t-first] of d - [t-create] of d) ]) ","
                   ([t-done] of d - [t-create] of d) ","
                   missed-flag)
end

; ===================== SAMPLING & FINALIZE =====================
to sample-run-stats
  let m mean [phi-de] of patches
  let v variance [phi-de] of patches
  set sum-phi-mean sum-phi-mean + m
  set sum-phi-var  sum-phi-var  + v
  set ticks-sampled ticks-sampled + 1
end

to finalize
  ;; close per-DE log if open
  if file-opened? [ file-close set file-opened? false ]

  ;; ensure run-summary header exists, then append this run
  if not file-exists? run-summary-file [
    file-open run-summary-file
    file-print "run_id,ticks,de_spawned,de_served,de_missed,service_throughput,miss_rate,mean_ttfr,mean_latency,energy_per_task,coverage_entropy,field_mean,field_var"
    file-close
  ]

  file-open run-summary-file
  file-print (word run-id "," ticks "," de-spawned "," de-served "," de-missed ","
                   service-throughput "," miss-rate "," mean-ttfr "," mean-latency ","
                   energy-per-task "," coverage-entropy "," field-mean "," field-var)
  file-close
end

; ===================== REPORTERS (BehaviorSpace) =====================

to-report service-throughput
  report (de-served / (max list 1 ticks))
end

to-report served-fraction
  report (de-served / (max list 1 de-spawned))
end

to-report miss-rate
  report (de-missed / (max list 1 de-spawned))
end

to-report mean-ttfr
  if ttfr-n = 0 [ report -1 ]
  report ttfr-sum / ttfr-n
end

to-report mean-latency
  if latency-n = 0 [ report -1 ]
  report latency-sum / latency-n
end


to-report energy-per-task
  report sum-energy / (max list 1 de-served)
end

to-report coverage-entropy
  ;; H = -Σ p_i ln p_i, using coarse coverage bins in cov-counts
  let n (bins-x * bins-y)
  let total 0
  let idx 0
  while [idx < n] [
    set total (total + (array:item cov-counts idx))
    set idx idx + 1
  ]
  if total = 0 [ report 0 ]
  let h 0
  set idx 0
  while [idx < n] [
    let c array:item cov-counts idx
    if c > 0 [
      let p (c / total)
      set h h + (- p * ln p)
    ]
    set idx idx + 1
  ]
  report h
end

to-report field-mean
  if ticks-sampled = 0 [ report 0 ]
  report (sum-phi-mean / ticks-sampled)
end

to-report field-var
  if ticks-sampled = 0 [ report 0 ]
  report (sum-phi-var / ticks-sampled)
end
@#$#@#$#@
GRAPHICS-WINDOW
210
10
648
449
-1
-1
13.0
1
10
1
1
1
0
1
1
1
-16
16
-16
16
0
0
1
ticks
30.0

BUTTON
706
171
773
205
Setup
setup\n
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
801
171
865
205
Go
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SLIDER
968
30
1141
63
diffDE
diffDE
0.1
0.6
0.2
0.02
1
NIL
HORIZONTAL

SLIDER
967
80
1140
113
decayDE
decayDE
0.01
0.08
0.02
0.005
1
NIL
HORIZONTAL

SLIDER
966
132
1139
165
diffHZ
diffHZ
0.01
0.4
0.05
0.01
1
NIL
HORIZONTAL

SLIDER
1214
364
1387
397
max-blocked-frac
max-blocked-frac
0.05
0.4
0.2
0.01
1
NIL
HORIZONTAL

SLIDER
1374
25
1547
58
wander-prob
wander-prob
0.1
0.6
0.1
0.05
1
NIL
HORIZONTAL

SLIDER
1374
125
1547
158
max-active-des
max-active-des
1
100
30.0
1
1
NIL
HORIZONTAL

SLIDER
1370
220
1543
253
p-hazard-change
p-hazard-change
0.001
0.05
0.02
0.001
1
NIL
HORIZONTAL

SLIDER
1373
76
1546
109
p-new-DE
p-new-DE
0.01
0.1
0.03
0.01
1
NIL
HORIZONTAL

SLIDER
1175
212
1348
245
kappa
kappa
0.5
2.5
0.5
0.1
1
NIL
HORIZONTAL

SLIDER
1174
303
1347
336
service-radius
service-radius
2
4
2.0
0.1
1
NIL
HORIZONTAL

SLIDER
1172
259
1344
292
service-rate
service-rate
0.5
1.5
1.0
0.1
1
NIL
HORIZONTAL

SLIDER
967
224
1139
257
leakDE
leakDE
0.01
0.2
0.01
0.01
1
NIL
HORIZONTAL

SLIDER
968
178
1140
211
decayHZ
decayHZ
0.01
0.05
0.01
0.005
1
NIL
HORIZONTAL

SLIDER
1175
29
1347
62
s0
s0
1
8
1.0
0.5
1
NIL
HORIZONTAL

SLIDER
1176
72
1348
105
alpha
alpha
0.1
1.0
0.3
0.05
1
NIL
HORIZONTAL

SLIDER
1176
119
1348
152
u-growth
u-growth
0.02
0.08
0.05
0.005
1
NIL
HORIZONTAL

SLIDER
1175
168
1347
201
u-max
u-max
8
15
10.0
1
1
NIL
HORIZONTAL

SLIDER
966
269
1138
302
de-cap
de-cap
20
60
25.0
5
1
NIL
HORIZONTAL

INPUTBOX
959
365
1189
425
run-seed
-1.0
1
0
Number

SLIDER
1213
407
1385
440
beacon-bonus
beacon-bonus
0
6
4.0
1
1
NIL
HORIZONTAL

SLIDER
1374
175
1546
208
miss-cutoff
miss-cutoff
100
4000
700.0
100
1
NIL
HORIZONTAL

SLIDER
965
312
1137
345
num-carriers
num-carriers
1
100
25.0
1
1
NIL
HORIZONTAL

SLIDER
1370
267
1542
300
max-ticks
max-ticks
1000
10000
5000.0
100
1
NIL
HORIZONTAL

SLIDER
1370
312
1542
345
de-quota
de-quota
0
1000
300.0
5
1
NIL
HORIZONTAL

SWITCH
1406
382
1518
415
verbose?
verbose?
1
1
-1000

MONITOR
286
521
343
566
ticks
ticks
17
1
11

MONITOR
370
521
459
566
de-spawned
de-spawned
17
1
11

MONITOR
484
520
561
565
de-served
de-served
17
1
11

MONITOR
584
520
663
565
de-missed
de-missed
17
1
11

MONITOR
237
592
373
638
served-fraction
served-fraction
2
1
11

MONITOR
404
594
478
640
miss-rate
miss-rate
2
1
11

MONITOR
499
592
573
638
mean-ttfr
mean-ttfr
17
1
11

MONITOR
594
590
692
636
mean-latency
mean-latency
17
1
11

MONITOR
288
667
405
713
energy-per-task
energy-per-task
4
1
11

MONITOR
424
668
550
714
coverage-entropy
coverage-entropy
4
1
11

MONITOR
577
669
657
715
field-mean
field-mean
4
1
11

MONITOR
687
670
754
716
field-var
field-var
4
1
11

PLOT
932
620
1232
818
Active Demands
ticks
count of active DEs
0.0
10.0
0.0
10.0
true
false
"clear-plot" ""
PENS
"active" 1.0 0 -16777216 true "" "plot count demands with [not served? and not missed?]"

PLOT
1248
618
1526
821
Served vs Missed
ticks
served, missed
0.0
10.0
0.0
10.0
true
false
"clear-plot" ""
PENS
"Served" 1.0 0 -10899396 true "" "plot de-served"
"Missed" 1.0 0 -2674135 true "" "plot de-missed"

PLOT
1546
619
1818
823
Mean Fields
ticks
mean of each field
0.0
10.0
0.0
10.0
true
false
"clear-plot" ""
PENS
"phiDE" 1.0 0 -16777216 true "" "plot mean [phi-de] of patches"
"phiHZ" 1.0 0 -7500403 true "" "plot mean [phi-hz] of patches"

PLOT
1252
838
1525
1028
Coverage Entropy
ticks
coverage-entropy
0.0
10.0
0.0
10.0
true
false
"clear-plot\n" ""
PENS
"entropy" 1.0 0 -16777216 true "" "plot coverage-entropy"

MONITOR
134
669
270
715
service-throughput
service-throughput
17
1
11

@#$#@#$#@
# What is this model?

X-SYCON is a passive, vascular-inspired control layer for swarm robots. Tasks (DEs) create an attractive diffusing field 𝜙𝐷𝐸; hazards create a repulsive field 𝜙𝐻𝑍. Carriers follow local gradients only—no global maps, no messaging—so the system continues working through comms blackouts. The first carrier to reach a DE turns it into a stronger beacon, improving subsequent arrivals.

This model is the open, reproducible baseline for the full research stack (X-SYCON → P-ADAPT → HYBRID).


# How it works (one tick)

1. DE urgency increases; sources reseed 𝜙𝐷𝐸 (with leak and cap).

2. Hazards mean-revert toward a target density; reseed 𝜙𝐻𝑍

3. Both fields diffuse & decay.

4. Carriers move to the best 4-neighbor by maximizing 𝜙𝐷𝐸 − 𝜅𝜙𝐻𝑍 with light separation and jitter.

5. DEs within service-radius accumulate work; first contact flips beacon on; completion logs TTFR/latency; overdue DEs become missed.


# Interface (sliders & switches)

## Field / environment

diffDE, decayDE, leakDE, de-cap — demand field dynamics

diffHZ, decayHZ — hazard field dynamics

p-hazard-change, max-blocked-frac — hazard evolution (mean-reverting)

## Demands

s0, alpha, u-growth, u-max — base + urgency gain

beacon-bonus — first-contact boost

p-new-DE — spawn probability; max-active-des — concurrent DE cap

miss-cutoff — timeout ticks before marking missed

## Carriers

num-carriers — swarm size

service-rate — work units per carrier per tick (parameter)

service-radius — work/sense radius

kappa — hazard aversion

wander-prob — small random wiggle when stuck

## Experiment control

max-ticks, de-quota — stop conditions (either one ends the run)

run-seed (−1 = random) — reproducibility

verbose? — show/hide GUI rendering during runs

## Plots (optional live diagnostics)

Active Demands: plot count demands with [not served? and not missed?]

Served vs Missed: pens plot de-served and plot de-missed

Mean Fields: pens plot mean [phi-de] of patches, plot mean [phi-hz] of patches

Service Throughput: plot service-throughput

Coverage Entropy: plot coverage-entropy

Obstacle Fraction: plot (count patches with [blocked?]) / (count patches)

(Plots/monitors do not affect headless BehaviorSpace performance.)


# What to measure (reporters)

service-throughput — DEs completed per tick

miss-rate — missed / spawned

mean-ttfr, mean-latency — per-DE timing

energy-per-task — movement proxy / served DE

coverage-entropy — herding vs dispersion

field-mean, field-var — demand-field stability


# Outputs

Per-DE logs: de-log-<run-id>.csv with run_id,de_id,t_create,t_first,t_done,ttfr,latency,missed

Run summaries: run-summary-<run-id>.csv with all reporters per run


# Reproducibility

Set run-seed to a fixed integer or let BehaviorSpace assign seeds per run. Each run gets a unique run-id used in filenames.


# License & citation

macOS Sonoma V14.4
X-SYCON NetLogo 6.4, Artur Baek, 2025, https://github.com/arthurbaek/biovascular-swarm-robotics
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
<experiments>
  <experiment name="x-sycon experiment" repetitions="1" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>(ticks &gt;= max-ticks) or ((de-served + de-missed) &gt;= de-quota)</exitCondition>
    <metric>service-throughput</metric>
    <metric>miss-rate</metric>
    <metric>mean-ttfr</metric>
    <metric>mean-latency</metric>
    <metric>energy-per-task</metric>
    <metric>coverage-entropy</metric>
    <metric>field-mean</metric>
    <metric>field-var</metric>
    <enumeratedValueSet variable="num-carriers">
      <value value="10"/>
      <value value="25"/>
      <value value="50"/>
      <value value="100"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p-new-DE">
      <value value="0.02"/>
      <value value="0.03"/>
      <value value="0.04"/>
      <value value="0.06"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="max-blocked-frac">
      <value value="0.1"/>
      <value value="0.15"/>
      <value value="0.22"/>
      <value value="0.28"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="kappa">
      <value value="0.5"/>
      <value value="0.8"/>
      <value value="1.2"/>
      <value value="1.6"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="run-seed">
      <value value="1"/>
      <value value="2"/>
      <value value="3"/>
      <value value="4"/>
      <value value="5"/>
      <value value="6"/>
      <value value="7"/>
      <value value="8"/>
      <value value="9"/>
      <value value="10"/>
    </enumeratedValueSet>
  </experiment>
</experiments>
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
