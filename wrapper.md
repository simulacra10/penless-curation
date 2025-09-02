# Running `curate.sh` from Anywhere

This guide shows how to set up `curate.sh` inside `~/Documents/curation`  
and run it as a simple `curate` command without typing the full path.

---

## 1. Move the project
```bash
mkdir -p ~/Documents
mv ~/penless-curation-v4 ~/Documents/curation
````

Now your main script is at:

```
~/Documents/curation/curate.sh
```

---

## 2. Create a wrapper script

Put a wrapper in `~/bin` (or `~/.local/bin` if you prefer):

```bash
mkdir -p ~/bin
cat > ~/bin/curate <<'EOF'
#!/usr/bin/env bash
# Wrapper to run curate.sh from ~/Documents/curation

exec ~/Documents/curation/curate.sh "$@"
EOF
chmod +x ~/bin/curate
```

---

## 3. Ensure `~/bin` is on your PATH

Add this line to `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="$HOME/bin:$PATH"
```

Reload your shell:

```bash
source ~/.bashrc
```

---

## 4. Use it anywhere

Now you can run the tool globally:

```bash
curate add "https://example.com" tag1 tag2
curate digest --hugo --archive
curate rules list
```

---

## Alternative: Symlink

Instead of a wrapper, you can symlink directly:

```bash
ln -s ~/Documents/curation/curate.sh ~/bin/curate
```

```

---
