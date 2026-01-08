default: format test build run

up: build run

check: format test build

build:
  zig build

format:
  zig fmt src

run:
  ./zig-out/bin/cardigan

# Test targets
test-unit flags="":
  zig build test-unit {{flags}}

test-integration flags="":
  zig build test-integration {{flags}}

test-system flags="":
  zig build test-system {{flags}}

test: test-unit test-integration test-system

test-verbose: (test-unit "--summary all") (test-integration "--summary all") (test-system "--summary-all")

## only shortcuts for humans below
## sweet shortcuts - conveniences for super common ops

# view in-progress tasks (interactive)
[group('shortcut')]
wip: gkd

# interactive: edit kanban/
[group('shortcut')]
ek:
    $EDITOR $(fd 'T\d{3,3}-\w+.md' kanban | sort | fzf )

# interactive: edit kanban/backlog
[group('shortcut')]
ekb:
    $EDITOR $(fd 'T\d{3,3}-\w+.md' kanban/backlog | sort | fzf )

# interactive: edit kanban/in-progress
[group('shortcut')]
ekd:
    $EDITOR $(fd 'T\d{3,3}-\w+.md' kanban/doing | sort | fzf )

# interactive: view kanban/
[group('shortcut')]
gk:
    glow -p $(fd 'T\d{3,3}-\w+.md' kanban | sort | fzf )

# interactive: view kanban/backlog
[group('shortcut')]
gkb:
    glow -p $(fd 'T\d{3,3}-\w+.md' kanban/backlog | sort | fzf )

# interactive: view kanban/in-progress
[group('shortcut')]
gkd:
    glow -p $(fd 'T\d{3,3}-\w+.md' kanban/doing | sort | fzf )

# interactive: move card
[group('shortcut')]
mvk:
    #/bin/sh
    file=$(fd 'T\d{3,3}_\w+.md' kanban | sort | fzf)
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

# create kanban task interactively
[group('shortcut')]
ck:
    .script/create_new_task.sh

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
