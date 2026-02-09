## Version Control that uses AmigaShell/FreeDOS .bat/Bash scripts

- Omi = Omni (all) or "Optimized Micro Index"
- Stores files to SQLite BLOBs without compression
- Simpler than Fossil SCM

## Uses commands like Git

Download `wekan.omi` SQLite database that includes all contents of repo:
```
omi clone https://omi.wekan.fi/wekan

cd wekan

omi add --all

omi commit -m "Updates"

omi push

cd ../repo2

omi pull
```

## Related files

- WeDOS, kanban made with FreeDOS .bat and Bash scripts: https://github.com/wekan/wedos
- SQLite for Amiga: https://aminet.net/search?query=sqlite&ord=DESC&sort=date
- Fossil SCM: https://github.com/howinfo/howinfo/wiki/Fossil
- FreeDOS: https://github.com/howinfo/howinfo/wiki/FreeDOS
- Amiga: https://github.com/howinfo/howinfo/wiki/Amiga

## Roadmap

- [ ] Create hash of file: `SELECT hex(sha256(data)) FROM files`
- [ ] Add file to database as BLOB and hash as TEXT
- [ ] ...
