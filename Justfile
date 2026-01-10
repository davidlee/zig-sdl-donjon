default: format generate test build run

up: build run

# you probably want this. Fast, comprehensive.
check: format generate test build

# alias, create with correct ID from template.
new-kanban: new-card

cue-vet:
  cue vet data/*.cue

build:
  zig build

format:
  zig fmt src

run:
  ./zig-out/bin/cardigan

generate:
  (cue export data/materials.cue data/weapons.cue data/techniques.cue data/armour.cue data/bodies.cue data/tests.cue --out json | ./scripts/cue_to_zig.py > src/gen/generated_data.zig)

# Audit CUE data completeness and consistency
audit-data:
  cue export data/materials.cue data/weapons.cue data/techniques.cue data/armour.cue data/bodies.cue data/tests.cue --out json | ./scripts/cue_to_zig.py --audit-report doc/artefacts/data_audit_report.md


# Test targets
[group('test')]
test-unit flags="":
  zig build test-unit {{flags}}

[group('test')]
test-integration flags="":
  zig build test-integration {{flags}}

[group('test')]
test-system flags="":
  zig build test-system {{flags}}

[group('test')]
test: test-unit test-integration test-system

# the output is not interesting.
[group('test')]
test-verbose: (test-unit "--summary all") (test-integration "--summary all") (test-system "--summary-all")

## only shortcuts for humans below
## sweet shortcuts - conveniences for super common ops

# view in-progress tasks (interactive)
[group('shortcut')]
wip: gkd

# interactive: edit kanban/
[group('shortcut')]
ek:
    $EDITOR $(fd 'T\d{3}' kanban | sort | fzf )

# interactive: edit kanban/backlog
[group('shortcut')]
ekb:
    $EDITOR $(fd 'T\d{3}' kanban/backlog | sort | fzf )

# interactive: edit kanban/in-progress
[group('shortcut')]
ekd:
    $EDITOR $(fd 'T\d{3}' kanban/doing | sort | fzf )

# interactive: view kanban/
[group('shortcut')]
gk:
    glow -p $(fd 'T\d{3}' kanban | sort | fzf )

# interactive: view kanban/backlog
[group('shortcut')]
gkb:
    glow -p $(fd 'T\d{3}' kanban/backlog | sort | fzf )

# interactive: view kanban/in-progress
[group('shortcut')]
gkd:
    glow -p $(fd 'T\d{3}' kanban/doing | sort | fzf )

# interactive: move card
[group('shortcut')]
mvk:
    #/bin/sh
    file=$(fd 'T\d{3}' kanban | sort | fzf)
    echo "git mv $file "
    folder=$(gum choose --header="Choose where:" $(fd -t d . kanban/ | sort))
    git mv $file $folder

# tree of kanban/
[group('shortcut')]
tk:
    tree kanban

# open yazi on kanban/
[group('shortcut')]
yk:
    yazi kanban

# create kanban card in backlog with correct ID from template
new-card desc="":
    #!/usr/bin/env python3
    import shutil
    import sys
    import re
    from pathlib import Path

    raw_desc = r"""{{desc}}""".strip()
    slug = ""
    if raw_desc:
        slug = re.sub(r"[^a-z0-9]+", "_", raw_desc.lower()).strip("_")

    repo_root = Path.cwd()
    kanban_dir = repo_root / "kanban"
    backlog_dir = kanban_dir / "backlog"
    template_path = kanban_dir / "template.md"

    if not template_path.exists():
        sys.exit(f"Template not found: {template_path}")

    pattern = re.compile(r"T(\d{3,})(?:[-_][\w]+)?\.md$", re.IGNORECASE)
    max_id = 0
    for path in kanban_dir.rglob("T*.md"):
        match = pattern.match(path.name)
        if match:
            max_id = max(max_id, int(match.group(1)))

    next_id = max_id + 1
    suffix = f"-{slug}" if slug else ""
    dest_name = f"T{next_id:03d}{suffix}.md"
    dest_path = backlog_dir / dest_name

    if dest_path.exists():
        sys.exit(f"Destination already exists: {dest_path}")

    shutil.copyfile(template_path, dest_path)
    print(f"Created {dest_path}")

# rename T###_foo.md to T###-foo.md for consistency
normalize-kanban:
    #!/usr/bin/env python3
    import subprocess
    import re
    from pathlib import Path

    kanban_dir = Path("kanban")
    pattern = re.compile(r"^(T\d{3})_(.+\.md)$")

    for path in kanban_dir.rglob("T*_*.md"):
        match = pattern.match(path.name)
        if match:
            new_name = f"{match.group(1)}-{match.group(2)}"
            new_path = path.parent / new_name
            print(f"git mv {path} -> {new_path}")
            subprocess.run(["git", "mv", str(path), str(new_path)], check=True)

## doc

# open editor on doc/ interactively
[group('shortcut')]
ed:
    $EDITOR $(fd '\w+.md' doc | sort | fzf )

# view doc/ interactive
[group('shortcut')]
gd:
    glow -p $(fd '\w+.md' doc | sort | fzf )

# open yazi on doc/
[group('shortcut')]
yd:
    yazi doc

# yazi - internal/
[group('shortcut')]
yi:
    yazi internal

# edit code - interactive
[group('shortcut')]
ec:
    $EDITOR $(fd '\w+.go' . | sort | fzf )%
