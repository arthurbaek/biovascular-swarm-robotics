; ============================================================
; X-SYCON (passive) — v4.2  (your v4.1 + missed + counters + TTFR in CSV)
; ============================================================

globals [
  ;; monitors
  last-ttfr
  last-latency

  ;; logging + run counters + timeout
  de-log-file
  de-spawned
  de-served
  de-missed
  miss-cutoff          ;; set in setup (or add an Interface input)
]

patches-own [
  phi-de
  phi-hz
  blocked?
]

breed [ carrierDrones carrierDrone ]
breed [ demands de ]

demands-own [
  t-create t-first t-done
  required-time remaining-time
  served?
  urgency
  beacon-on?
  missed?               ;; NEW: timed out before service?
]

; ===================== SETUP =====================
to setup
  clear-all

  ask patches [
    set phi-de 0
    set phi-hz 0
    set blocked? false
  ]

  setup-obstacles

  ;; CSV init
  set de-log-file "de-log.csv"
  if file-exists? de-log-file [ file-delete de-log-file ]
  file-open de-log-file
  file-print "de_id,t_create,t_first,t_done,ttfr,latency,missed"
  file-close

  ;; run counters + timeout (you can add a slider or input for miss-cutoff)
  set de-spawned 0
  set de-served  0
  set de-missed  0
  set miss-cutoff 3000

  reset-ticks

  repeat 2 [ create-one-de ]

  create-carrierDrones 25 [
    set color blue
    set size 1.2
    set heading random 360
    let placed? false
    while [ not placed? ] [
      setxy random-xcor random-ycor
      if (not [blocked?] of patch-here) and (not any? other carrierDrones in-radius 1.0) [
        set placed? true
      ]
    ]
  ]

  update-demands-urgency
  update-fields
  colorize-fields
end

; ===================== MAIN LOOP =====================
to go
  update-demands-urgency
  update-fields
  evolve-environment
  colorize-fields
  move-carriers
  service-and-complete
  tick
end

; ===================== DYNAMIC ENVIRONMENT =====================
to evolve-environment
  ;; spontaneous DEs respecting active cap
  if (count demands with [not served?] < max-active-des) and (random-float 1 < p-new-DE) [
    create-one-de
  ]

  ;; gentle hazard evolution with density guard
  if random-float 1 < p-hazard-change [
    let blk-frac (count patches with [blocked?]) / (count patches)
    ask one-of patches [
      ifelse blocked? [
        set blocked? false
        set phi-hz 0
      ] [
        if blk-frac < max-blocked-frac [
          set blocked? true
          set phi-hz 12
        ]
      ]
    ]
  ]
end

; ===================== OBSTACLES (randomized) =====================
to setup-obstacles
  ask patches [
    set blocked? false
    set phi-hz 0
  ]
  ask n-of (count patches * 0.12) patches [
    set blocked? true
    set phi-hz 12
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
  set size 1.6
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

  ;; absolute leak (your choice) to keep background from drifting up
  ask patches [
    set phi-de max list 0 (phi-de - leakDE)
  ]

  ;; reseed hazards
  ask patches with [ blocked? ] [
    set phi-hz 12
  ]

  ;; reseed demand: base + urgency + beacon bump, with local cap
  ask demands with [ not served? and not missed? ] [
    let s (s0 + alpha * urgency + (ifelse-value beacon-on? [4] [0]))
    ask patch-here [
      set phi-de phi-de + s
      if de-cap > 0 [ set phi-de min list phi-de de-cap ]
    ]
  ]

  ;; diffuse (mass-conserving)
  diffuse phi-de diffDE
  diffuse phi-hz diffHZ
end

; ===================== VIS (min–max scaling) =====================
to colorize-fields
  let m  max [phi-de] of patches
  let mn min [phi-de] of patches
  if m = mn [ set m mn + 1 ]   ;; avoid zero range
  ask patches [
    set pcolor ifelse-value blocked? [ grey - 3 ] [ scale-color red phi-de mn m ]
  ]
end

; ===================== MOTION =====================
to move-carriers
  ask carrierDrones [

    ;; separation side-step
    if any? other carrierDrones in-radius 0.8 [
      rt one-of [-30 30]
      if not [blocked?] of patch-ahead 1 [ fd 1 ]
      stop
    ]

    let candidates neighbors4 with [ not blocked? ]

    ifelse any? candidates [
      ;; always move to best neighbor (prevents parking on flat fields)
      let best max-one-of candidates [
        (phi-de - (kappa * phi-hz))
        - 0.15 * count carrierDrones-here
        + random-float 0.01
      ]
      face best
      if not [blocked?] of patch-ahead 1 [ fd 1 ]
    ] [
      ;; boxed in: wiggle
      if random-float 1 < wander-prob [
        rt one-of [-90 -45 45 90]
        if not [blocked?] of patch-ahead 1 [ fd 1 ]
      ]
    ]
  ]
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

    ;; completion
    if remaining-time = 0 [
      set served? true
      set t-done ticks
      set color green
      set last-ttfr    (t-first - t-create)
      set last-latency (t-done  - t-create)
      set de-served    de-served + 1
      log-de-row self 0
      die
    ]

    ;; timeout → missed
    if (ticks - t-create) > miss-cutoff [
      set missed? true
      set served? true
      set t-done ticks
      set color violet
      set last-ttfr    (ifelse-value (t-first = -1) [ -1 ] [ t-first - t-create ])
      set last-latency (t-done - t-create)
      set de-missed    de-missed + 1
      log-de-row self 1
      die
    ]
  ]
end

to log-de-row [ d missed-flag ]
  file-open de-log-file
  file-print (word [who] of d "," [t-create] of d "," [t-first] of d "," [t-done] of d ","
                   (ifelse-value ([t-first] of d = -1) [ -1 ] [ ([t-first] of d - [t-create] of d) ]) ","
                   ([t-done] of d - [t-create] of d) ","
                   missed-flag)
  file-close
end

; ===================== RUN SUMMARY CSV =====================
to write-run-summary
  let run-file "run-summary.csv"
  let served-rate  de-served / (max list 1 de-spawned)
  let missed-rate  de-missed / (max list 1 de-spawned)

  if not file-exists? run-file [
    file-open run-file
    file-print "run_id,ticks,de_spawned,de_served,de_missed,service_rate,miss_rate"
    file-close
  ]

  ;; simple unique id per click (you can make a global run-id if you prefer)
  let rid (word "r" precision random-float 1.0 6)

  file-open run-file
  file-print (word rid "," ticks "," de-spawned "," de-served "," de-missed ","
                   served-rate "," missed-rate)
  file-close
end

@#$#@#$#@
GRAPHICS-WINDOW
210
10
652
454
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
setup\nset-current-plot \"Outcomes\"     clear-plot\nset-current-plot \"Environment\"  clear-plot\nset-current-plot \"TTFR & Latency\" clear-plot\n
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
965
30
1138
64
diffDE
diffDE
0.1
0.6
0.36
0.02
1
NIL
HORIZONTAL

SLIDER
967
80
1140
114
decayDE
decayDE
0.01
0.08
0.04
0.005
1
NIL
HORIZONTAL

SLIDER
977
148
1150
182
diffHZ
diffHZ
0.1
0.4
0.24
0.02
1
NIL
HORIZONTAL

SLIDER
985
213
1158
247
max-blocked-frac
max-blocked-frac
0.05
0.4
0.22
0.01
1
NIL
HORIZONTAL

SLIDER
986
280
1159
314
wander-prob
wander-prob
0.1
0.6
0.35
0.05
1
NIL
HORIZONTAL

SLIDER
997
334
1170
368
max-active-des
max-active-des
1
10
6.0
1
1
NIL
HORIZONTAL

SLIDER
1034
381
1207
415
p-hazard-change
p-hazard-change
0.0001
0.002
6.0E-4
0.0001
1
NIL
HORIZONTAL

SLIDER
1012
436
1185
470
p-new-DE
p-new-DE
0.0002
0.002
0.0012
0.0001
1
NIL
HORIZONTAL

SLIDER
1019
501
1192
535
kappa
kappa
0.5
2
1.2
0.1
1
NIL
HORIZONTAL

SLIDER
1016
563
1189
597
service-radius
service-radius
0.5
3.0
1.8
0.1
1
NIL
HORIZONTAL

SLIDER
1273
54
1445
87
service-rate
service-rate
0.5
3
1.0
0.1
1
NIL
HORIZONTAL

SLIDER
1284
120
1456
153
leakDE
leakDE
0.05
0.2
0.15
0.01
1
NIL
HORIZONTAL

SLIDER
1286
175
1458
208
decayHZ
decayHZ
0.01
0.05
0.02
0.005
1
NIL
HORIZONTAL

SLIDER
1294
234
1466
267
s0
s0
2
8
4.0
0.5
1
NIL
HORIZONTAL

SLIDER
1297
296
1469
329
alpha
alpha
0.4
1.0
0.6
0.05
1
NIL
HORIZONTAL

SLIDER
1302
375
1474
408
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
1309
438
1481
471
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
1321
527
1493
560
de-cap
de-cap
20
60
25.0
5
1
NIL
HORIZONTAL

MONITOR
333
538
423
584
de-spawned
de-spawned
17
1
11

MONITOR
458
556
536
602
de-served
de-served
17
1
11

MONITOR
595
560
675
606
de-missed
de-missed
17
1
11

MONITOR
737
563
800
609
last-ttfr
last-ttfr
17
1
11

MONITOR
337
647
424
693
last-latency
last-latency
17
1
11

MONITOR
546
683
620
729
miss-rate
de-missed / (max list 1 de-spawned)
4
1
11

MONITOR
699
686
788
732
service-rate
de-served / (max list 1 de-spawned)
4
1
11

MONITOR
358
764
438
810
active-DEs
count demands with [ not served? and not missed? ]
17
1
11

MONITOR
516
768
610
814
blocked-frac
(count patches with [ blocked? ]) / count patches
4
1
11

PLOT
894
709
1094
859
Outcomes
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"served" 1.0 0 -10899396 true "" "plot de-served"
"missed" 1.0 0 -2674135 true "" "plot de-missed"

PLOT
1205
736
1405
886
Environment
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"blocked-frac" 1.0 0 -16777216 true "" "plot ( (count patches with [ blocked? ]) / count patches )"
"active-DEs" 1.0 0 -13791810 true "" "plot count demands with [ not served? and not missed? ]"

PLOT
1548
783
1748
933
TTFR & Latency
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"ttfr" 1.0 0 -16777216 true "" "if last-ttfr >= 0 [ plot last-ttfr ]"
"latency" 1.0 0 -7500403 true "" "if last-latency > 0 [ plot last-latency ]"

BUTTON
760
265
880
299
Save Summary
write-run-summary
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

@#$#@#$#@
## WHAT IS IT?

(a general understanding of what the model is trying to show or explain)

## HOW IT WORKS

(what rules the agents use to create the overall behavior of the model)

## HOW TO USE IT

(how to use the model, including a description of each of the items in the Interface tab)

## THINGS TO NOTICE

(suggested things for the user to notice while running the model)

## THINGS TO TRY

(suggested things for the user to try to do (move sliders, switches, etc.) with the model)

## EXTENDING THE MODEL

(suggested things to add or change in the Code tab to make the model more complicated, detailed, accurate, etc.)

## NETLOGO FEATURES

(interesting or unusual features of NetLogo that the model uses, particularly in the Code tab; or where workarounds were needed for missing features)

## RELATED MODELS

(models in the NetLogo Models Library and elsewhere which are of related interest)

## CREDITS AND REFERENCES

(a reference to the model's URL on the web if it has one, as well as any other necessary credits, citations, and links)
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
