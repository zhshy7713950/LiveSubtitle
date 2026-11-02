#!/usr/bin/env python3
"""Check deliverable links, task inventory and the shared Xcode scheme."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
required = [
    'AGENTS.md', 'AGENT.md', 'CLAUDE.md', 'README.md',
    'docs/development-spec.md', 'docs/scaffold-design.md',
    'docs/project-constraints.md', 'docs/architecture.md',
    'docs/tasks/README.md', 'docs/tasks/HANDOFF.md',
    'docs/reports/G0-template.md', 'docs/reports/acceptance-template.md',
    'docs/plans/2026-11-02-development.md',
]
errors = [f'Missing: {path}' for path in required if not (ROOT / path).is_file()]
cards = sorted((ROOT / 'docs/tasks').glob('TASK-*.md'))
ids = [re.match(r'TASK-(\d+)-', path.name).group(1) for path in cards]
if ids != [f'{i:02}' for i in range(1, 16)]:
    errors.append(f'Expected TASK-01 through TASK-15 exactly once, got {ids}')
for card in cards:
    for heading in ('## 文件所有权', '## 接口', '## 验收', '## 执行步骤'):
        if heading not in card.read_text():
            errors.append(f'{card.relative_to(ROOT)}: missing {heading}')
for path in [ROOT / name for name in required] + list((ROOT / 'docs').rglob('*.md')):
    if not path.is_file():
        continue
    for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', path.read_text()):
        if '://' in target or target.startswith('#'):
            continue
        target = target.split('#', 1)[0]
        if not (path.parent / target).exists():
            errors.append(f'{path.relative_to(ROOT)}: broken link {target}')
scheme = ET.parse(ROOT / 'LiveSubtitle.xcodeproj/xcshareddata/xcschemes/LiveSubtitle.xcscheme')
tests = scheme.findall('.//TestableReference/BuildableReference')
if len(tests) != 1 or tests[0].get('BlueprintName') != 'LiveSubtitleTests':
    errors.append('Shared scheme must include LiveSubtitleTests exactly once')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Documentation links, {len(cards)} task cards and shared scheme: OK')
