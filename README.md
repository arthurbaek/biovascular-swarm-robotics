# X–SYCON: Xylem-Inspired Passive Gradient Control for Communication-Free Swarm Response

**Authors**  
Arthur Ji Sung Baek — Independent Researcher, São Paulo, Brazil — <ajsb2371@columbia.edu>  
Geoffrey H. Martin — Cornell University, Ithaca, NY, USA — <ghm58@cornell.edu>

[![arXiv](https://img.shields.io/badge/preprint-arXiv-8A2BE2.svg)]

> **Abstract** — We present **X–SYCON**, a xylem-inspired multi-agent architecture where coordination emerges from **passive field dynamics** (diffusion + decay) rather than explicit communication. Incidents (demands) and obstructions (hazards) write scalar fields; agents greedily ascend a local utility \(U=\phi_{\mathrm{DE}}-\kappa\phi_{\mathrm{HZ}}\) with light anti-congestion. A first-contact **beaconing** rule deepens local sinks to finish tasks faster without hurting time-to-first-response. We analyze a **hydraulic length scale** that predicts recruitment range and provide an **Ohm-law** service bound consistent with sublinear capacity scaling. Across 2,560 NetLogo/BehaviorSpace runs in dynamic, partially blocked worlds, we observe low miss rates, robust throughput, and tunable energy–reliability trade-offs—illustrating a class we call **Distributed Passive Computation & Control**.

---

## Contents
- [Quick start](#quick-start)
- [Results & figures](#results--figures)
- [Configuration](#configuration)
- [Citing this work](#citing-this-work)
- [Declarations (Data/COI/Funding/Ethics)](#declarations-data-coifundingethics)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Quick start

### Requirements
- **NetLogo 6.4: <https://ccl.northwestern.edu/netlogo/>  
- *(Optional)* **Python 3.10+** with `pandas`, `numpy`, `matplotlib` for analysis.

### Run the model interactively
1. Open `model/xsycon.nlogo` in NetLogo.  
2. Click **Setup**, then **Go**.  
3. Adjust sliders:
   - `kappa (κ)` — hazard penalty  
   - `pnew` — demand arrival probability  
   - `hazard` — blocked-cell fraction (target)  
   - `carriers (C)` — team size  
   - `diffusion/decay parameters` (DE/HZ)

### Batch runs (BehaviorSpace)
1. NetLogo → **Tools → BehaviorSpace**.  
2. Export CSVs

---

## Citing this work

If you use X–SYCON or its results, please cite the preprint

Preprint
Baek, A. J. S., & Martin, G. H. (2025). X–SYCON: Xylem-Inspired Passive Gradient Control for Communication-Free Swarm Response in Dynamic Disaster Environments. Preprint. arXiv: []

BibTeX

@misc{baek2025xsycon,
  title         = {X--SYCON: Xylem-Inspired Passive Gradient Control for Communication-Free Swarm Response in Dynamic Disaster Environments},
  author        = {Baek, Arthur Ji Sung and Martin, Geoffrey H.},
  year          = {2025},
  eprint        = {DOI},
  archivePrefix = {arXiv},
  primaryClass  = {cs.RO},
  doi = 
}

---

## Declarations (Data/COI/Funding/Ethics)   

Competing Interests — The authors declare no competing interests.

Funding — This research received no specific grant from any funding agency in the public, commercial, or not-for-profit sectors.

Ethics — This study did not involve human participants, animal experiments, or field studies requiring institutional review. No ethical approval was required.

---

## License

Code is released under the MIT License (see LICENSE).
Data in /data (and any files explicitly marked as “Data”) are released under CC BY 4.0 (see LICENSE-DATA).

Component	License
Code (outside /data)	MIT
Data (in /data)	CC BY 4.0

If you need permissions beyond the data license (e.g., commercial reuse under different terms), contact the corresponding author.

---

## Acknowledgments

We thank colleagues for feedback on early drafts and reviewers for helpful suggestions. Any views and errors are our own.


