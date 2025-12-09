# wpnus-2025

This repository contains the code and artifacts for the Workplace Ninjas US 2025 workshop sessions.

Purpose

- Provide four self-contained demos for conference attendees.
- Make the repo easy to clone, run, and distribute as workshop material.

Quick start (for attendees)

1. Clone the repository:
   git clone https://github.com/DanStutz/wpnus-2025.git
2. Change to the repo directory and open the demo index:
   cd wpnus-2025
   less DEMOS.md
3. Pick a demo folder under `demos/` and follow its README. Each demo is self-contained and includes sample data and step-by-step instructions.

Repository layout

- DEMOS.md — overview and how the four demos map to folders
- demos/demo-1 — demo 1 materials and README
- demos/demo-2 — demo 2 materials and README
- demos/demo-3 — demo 3 materials and README
- demos/demo-4 — demo 4 materials and README
- .github/workflows/ci.yml — CI template (runs lint/test where applicable)

Support

- If you find an issue, please create an issue using the templates in .github/ISSUE_TEMPLATE.
- See CONTRIBUTING.md for how to contribute improvements.

License

- This repo is distributed under the MIT License. See LICENSE for details.
