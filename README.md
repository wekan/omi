## Version Control that uses AmigaShell/FreeDOS .bat/Bash scripts

- Omi = Omni (all) or "Optimized Micro Index"
- Stores files to SQLite BLOBs without compression
- Simpler than Fossil SCM

## Uses commands like Git

Download wekan.omi
```
omi clone https://omi.wekan.fi/wekan

cd wekan

omi add --all

omi commit -m "Updates"

omi push

cd ../repo2

omi pull
```

## Roadmap

- [] Create hash of file: `SELECT hex(sha256(data)) FROM files`
- [] Add file to database as BLOB and hash as TEXT
- ...
