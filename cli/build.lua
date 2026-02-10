-- Omi build menu (Lua)

local root = arg[0]:gsub("[\\/][^\\/]+$", "")
if root == "" then root = "." end
local build = root .. "/build"

local function mkdir(path)
  os.execute(string.format("mkdir -p %q", path))
end

local function run(cmd)
  print(cmd)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

local function build_haxe(target)
  mkdir(build .. "/" .. target)
  if target == "cpp" then
    run(string.format("haxe -cp %q -main Omi -cpp %q", root, build .. "/cpp"))
  elseif target == "js" then
    run(string.format("haxe -cp %q -main Omi -js %q", root, build .. "/js/omi.js"))
  elseif target == "python" then
    run(string.format("haxe -cp %q -main Omi -python %q", root, build .. "/python/omi.py"))
  elseif target == "php" then
    run(string.format("haxe -cp %q -main Omi -php %q", root, build .. "/php"))
  elseif target == "cs" then
    run(string.format("haxe -cp %q -main Omi -cs %q", root, build .. "/cs"))
  elseif target == "java" then
    run(string.format("haxe -cp %q -main Omi -java %q", root, build .. "/java"))
  end
end

local function build_c89()
  mkdir(build .. "/c89")
  if os.execute("gcc --version > /dev/null 2>&1") == 0 then
    run(string.format("gcc -std=c89 -O2 -o %q %q -lsqlite3", build .. "/c89/omi", root .. "/omi.c"))
  elseif os.execute("clang --version > /dev/null 2>&1") == 0 then
    run(string.format("clang -std=c89 -O2 -o %q %q -lsqlite3", build .. "/c89/omi", root .. "/omi.c"))
  else
    print("No C compiler found (gcc/clang). Skipping C89 build.")
  end
end

local function build_csharp()
  mkdir(build .. "/csharp")
  if os.execute("mcs --version > /dev/null 2>&1") == 0 then
    run(string.format("mcs -out:%q %q -r:System.Data.SQLite", build .. "/csharp/omi.exe", root .. "/omi.cs"))
  else
    print("mcs not found. Skipping C# build.")
  end
end

local function build_all()
  build_haxe("cpp")
  build_haxe("js")
  build_haxe("python")
  build_haxe("php")
  build_haxe("cs")
  build_haxe("java")
  build_c89()
  build_csharp()
end

print("Build targets:")
print(" 1) All (Haxe + C89 + C#)")
print(" 2) Haxe: cpp")
print(" 3) Haxe: js")
print(" 4) Haxe: python")
print(" 5) Haxe: php")
print(" 6) Haxe: cs")
print(" 7) Haxe: java")
print(" 8) C89 (native)")
print(" 9) C# / Mono")
print(" 0) Quit")

io.write("Select target: ")
local choice = io.read("*l")

if choice == "1" then
  build_all()
elseif choice == "2" then
  build_haxe("cpp")
elseif choice == "3" then
  build_haxe("js")
elseif choice == "4" then
  build_haxe("python")
elseif choice == "5" then
  build_haxe("php")
elseif choice == "6" then
  build_haxe("cs")
elseif choice == "7" then
  build_haxe("java")
elseif choice == "8" then
  build_c89()
elseif choice == "9" then
  build_csharp()
end

print("Build complete. Output in " .. build)
