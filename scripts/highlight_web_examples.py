#!/usr/bin/env python3
"""Generate lazy-loaded C3 source panels for the showcase using inkfmt."""
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXAMPLES = {
    'inputbox': 'inputbox/inputbox.c3',
    'spinners': 'spinners/spinners.c3',
    'tabs': 'tabs/tabs.c3',
    'progress': 'progress/progress.c3',
    'clock': 'clock/clock.c3',
    'nanobots': 'nanobots/nanobots.c3',
    'splash': 'splash/splash.c3',
    'doom-fire': 'doom-fire/doom-fire.c3',
    'doom-fire-tea': 'doom-fire/doom-fire-overlay.c3',
    'spotlight': 'spotlight/spotlight.c3',
    'avian-assault': 'avian-assault/avian-assault.c3',
}

for name, source in EXAMPLES.items():
    result = subprocess.check_output(
        ['inkfmt', '--lang', 'c3', '--html'],
        input=(ROOT / 'examples' / source).read_text(), text=True,
        cwd=os.environ.get('INKFMT_DIR', ROOT))
    html = re.sub(r'<style>.*?</style>\s*', '', result, flags=re.S)
    (ROOT / 'web/code' / f'{name}.html').write_text(html)
