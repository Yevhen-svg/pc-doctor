# PC Doctor: профили игр. Когда выбранная игра запускается, программа сама включает игровой профиль,
# закрывает выбранные фоновые программы и поднимает игре приоритет. Когда игра закрывается, возвращается только то, что включила программа.
$script:MockRunning = @()
$script:ExeRx = '^[A-Za-z0-9_.()\- ]{1,64}$'
$script:FoundCache = $null; $script:FoundT = [datetime]::MinValue
$script:ProcSnap = @(); $script:ProcSnapT = [datetime]::MinValue
$script:Armed = @{}
$script:IconTried = @{}
$script:SteamSkipRx = '(?i)^(Steamworks|Steam Linux Runtime|Proton|Steam Controller|SteamVR|Wallpaper Engine|Blender|Aseprite|Krita|OBS|DaVinci|Live2D|Spine|VTube|Soundpad|Lively|Source SDK|Godot|Unity|Unreal|RPG Maker|GameMaker|Firealpaca|Paint|Movavi|Filmora)|(?i)(Redistributable|Dedicated Server|\bSDK\b|Authoring Tools|Benchmark Tool|Demo Tool)'
$script:LnkSkipRx = '(?i)(chrome|edge|firefox|opera|brave|vivaldi|nvidia|geforce|overlay|discord|telegram|whatsapp|viber|steam\.exe|^steam$|epic games launcher|battle\.net|ubisoft connect|ea app|origin|gog galaxy|office|word|excel|powerpoint|outlook|onenote|teams|zoom|skype|spotify|obs|vlc|notepad|visual studio|\bcode\b|figma|photoshop|premiere|illustrator|after effects|adobe|davinci|capcut|claude|anthropic|chatgpt|docker|python|\bgit\b|terminal|powershell|\bcmd\b|control panel|cpu-?z|gpu-?z|afterburner|hwinfo|aida|razer|logitech|corsair|icue|synapse|ghub|radeon|adrenalin|winrar|7-?zip|torrent|anydesk|teamviewer|vpn|antivirus|kaspersky|avast|eset|malwarebytes|ccleaner|uninstall|setup|installer)'
function Games-Path { Join-Path $script:AppDir 'games.json' }
function Games-Load {
    $d = Json-Read (Games-Path) $null
    $games = @(); $active = $null
    if ($d) { $games = @($d.games | Where-Object { $_ }); $active = $d.active }
    return [ordered]@{ games = $games; active = $active }
}
function Games-Save($games, $active) { Json-Write (Games-Path) ([ordered]@{ games = @($games); active = $active }) }
function Clean-Exe($x) { $e = ([string]$x).Trim() -replace '\.exe$', ''; if ($e -match $script:ExeRx) { return $e }; return $null }
function G-Prop($g, $n) { if ($g.PSObject.Properties[$n]) { return [string]$g.$n }; return '' }
function Game-Rec($g) {
    [ordered]@{ id = $g.id; name = $g.name; exe = (G-Prop $g 'exe'); dir = (G-Prop $g 'dir'); appid = (G-Prop $g 'appid'); launch = (G-Prop $g 'launch'); kind = (G-Prop $g 'kind'); close = @($g.close); auto = [bool]$g.auto }
}

# ---------- процессы: по папке установки (надёжнее, чем по имени exe) ----------
function Get-ProcSnap {
    if (((Get-Date) - $script:ProcSnapT).TotalSeconds -lt 2) { return $script:ProcSnap }
    $l = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $pa = $null; try { $pa = $p.Path } catch { }; if ($pa) { $l += [pscustomobject]@{ P = $p; Path = $pa } } }
    $script:ProcSnap = $l; $script:ProcSnapT = Get-Date
    return $l
}
function Under-Dir($path, $dir) { return ($dir -and $path -and $path.StartsWith(($dir.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) }
function Game-Procs($g) {
    $exe = G-Prop $g 'exe'; $dir = G-Prop $g 'dir'
    if ($script:MockMode) { if ($exe -and ($script:MockRunning -contains $exe)) { return @([pscustomobject]@{ Id = 1; ProcessName = $exe; mock = $true }) }; return @() }
    if ($dir) { return @(Get-ProcSnap | Where-Object { Under-Dir $_.Path $dir } | ForEach-Object { $_.P }) }
    if ($exe) { return @(Get-Process -Name $exe -ErrorAction SilentlyContinue) }
    return @()
}
function Game-Learn-Exe($g, $procs) {
    if ($script:MockMode -or (G-Prop $g 'exe')) { return }
    $p = @($procs | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
    if (-not $p.Count) { $p = @($procs | Select-Object -First 1) }
    if (-not $p.Count) { return }
    $e = Clean-Exe $p[0].ProcessName; if (-not $e) { return }
    $st = Games-Load; $new = @()
    foreach ($x in $st.games) { if ($x.id -eq $g.id) { $r = Game-Rec $x; $r.exe = $e; $x = $r }; $new += $x }
    Games-Save $new $st.active
}

# ---------- поиск установленных игр ----------
function Get-SteamRoot {
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop; $v = $(if ($p.SteamPath) { $p.SteamPath } else { $p.InstallPath }); if ($v) { $v = ([string]$v) -replace '/', '\'; if (Test-Path -LiteralPath $v) { return $v } } } catch { }
    }
    return $null
}
function Get-SteamGames {
    $root = Get-SteamRoot; if (-not $root) { return @() }
    $libs = @($root)
    $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) { try { foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } } catch { } }
    $out = @(); $seen = @{}
    foreach ($lib in @($libs | Select-Object -Unique)) {
        $sa = Join-Path $lib 'steamapps'; if (-not (Test-Path -LiteralPath $sa)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $sa -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
            try {
                $t = [IO.File]::ReadAllText($f.FullName)
                $id = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
                $nm = [regex]::Match($t, '"name"\s+"([^"]*)"').Groups[1].Value
                $in = [regex]::Match($t, '"installdir"\s+"([^"]*)"').Groups[1].Value
                if (-not $id -or -not $nm -or -not $in -or $seen[$id]) { continue }
                if ($nm -match $script:SteamSkipRx) { continue }
                $dir = Join-Path (Join-Path $sa 'common') $in
                if (-not (Test-Path -LiteralPath $dir)) { continue }
                $seen[$id] = $true
                $out += [ordered]@{ key = ('steam:' + $id); name = $nm; kind = 'steam'; appid = $id; dir = $dir; exe = ''; launch = '' }
            } catch { }
        }
    }
    return $out
}
function Get-ShortcutGames {
    $out = @(); $seen = @{}
    $dirs = @(); foreach ($n in 'Desktop', 'CommonDesktopDirectory') { try { $d = [Environment]::GetFolderPath($n); if ($d) { $dirs += $d } } catch { } }
    try { $sh = New-Object -ComObject WScript.Shell } catch { return @() }
    foreach ($d in $dirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            try {
                $t = $sh.CreateShortcut($f.FullName).TargetPath
                if (-not $t -or $t -notmatch '\.exe$' -or -not (Test-Path -LiteralPath $t)) { continue }
                $nm = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                if (("$nm $t") -match $script:LnkSkipRx) { continue }
                if ($t -match '(?i)^[A-Z]:\\(Windows|ProgramData)\\|\\WindowsApps\\|\\Microsoft\\') { continue }
                $k = 'lnk:' + $t.ToLower(); if ($seen[$k]) { continue }; $seen[$k] = $true
                $dir = Split-Path -Parent $t
                if ($dir -match '(?i)^[A-Z]:\\?$|^[A-Z]:\\Program Files( \(x86\))?\\?$') { $dir = '' }
                $out += [ordered]@{ key = $k; name = $nm; kind = 'lnk'; appid = ''; dir = $dir; exe = (Clean-Exe ([IO.Path]::GetFileName($t))); launch = $t }
            } catch { }
        }
    }
    return $out
}
function Games-Discover([bool]$force) {
    if (-not $force -and $script:FoundCache -and ((Get-Date) - $script:FoundT).TotalSeconds -lt 90) { return $script:FoundCache }
    if ($script:MockMode) {
        $l = @(
            [ordered]@{ key = 'steam:2073620'; name = 'Arena Breakout: Infinite'; kind = 'steam'; appid = '2073620'; dir = 'D:\SteamLibrary\steamapps\common\Arena Breakout Infinite'; exe = 'ArenaBreakoutInfinite'; launch = '' },
            [ordered]@{ key = 'steam:730'; name = 'Counter-Strike 2'; kind = 'steam'; appid = '730'; dir = 'C:\Steam\steamapps\common\Counter-Strike Global Offensive'; exe = 'cs2'; launch = '' },
            [ordered]@{ key = 'steam:1091500'; name = 'Cyberpunk 2077'; kind = 'steam'; appid = '1091500'; dir = 'D:\SteamLibrary\steamapps\common\Cyberpunk 2077'; exe = 'Cyberpunk2077'; launch = '' },
            [ordered]@{ key = 'lnk:valorant'; name = 'VALORANT'; kind = 'lnk'; appid = ''; dir = 'C:\Riot Games\VALORANT'; exe = 'VALORANT-Win64-Shipping'; launch = 'C:\Riot Games\VALORANT\live\VALORANT.exe' })
        $script:FoundCache = $l; $script:FoundT = Get-Date; return $l
    }
    $l = @(Get-SteamGames) + @(Get-ShortcutGames)
    $script:FoundCache = $l; $script:FoundT = Get-Date
    return $l
}
function Games-Found {
    $have = Games-Load
    $out = @()
    foreach ($c in @(Games-Discover $false)) {
        $dup = $false
        foreach ($g in $have.games) { if (((G-Prop $g 'appid') -and (G-Prop $g 'appid') -eq $c.appid) -or ((G-Prop $g 'dir') -and (G-Prop $g 'dir') -ieq $c.dir) -or ((G-Prop $g 'launch') -and (G-Prop $g 'launch') -ieq $c.launch)) { $dup = $true } }
        if (-not $dup) { $out += [ordered]@{ key = $c.key; name = $c.name; kind = $c.kind } }
    }
    return [ordered]@{ found = @($out | Sort-Object { $_.name }); steam = [bool](Get-SteamRootSafe) }
}
function Get-SteamRootSafe { if ($script:MockMode) { return $true }; return (Get-SteamRoot) }
function Game-Add-Found($key, $close, $auto) {
    $c = @(Games-Discover $false | Where-Object { $_.key -eq [string]$key }) | Select-Object -First 1
    if (-not $c) { $c = @(Games-Discover $true | Where-Object { $_.key -eq [string]$key }) | Select-Object -First 1 }
    if (-not $c) { return [ordered]@{ ok = $false; message = 'Такой игры в списке найденных нет. Обновите список.' } }
    $st = Games-Load
    if ($st.games.Count -ge 30) { return [ordered]@{ ok = $false; message = 'В списке уже 30 игр.' } }
    foreach ($g in $st.games) { if (((G-Prop $g 'appid') -and (G-Prop $g 'appid') -eq $c.appid) -or ((G-Prop $g 'launch') -and (G-Prop $g 'launch') -ieq $c.launch)) { return [ordered]@{ ok = $false; message = 'Эта игра уже в списке.' } } }
    $n = [string]$c.name; if ($n.Length -gt 60) { $n = $n.Substring(0, 60) }
    $g = [ordered]@{ id = [guid]::NewGuid().ToString(); name = $n; exe = [string]$c.exe; dir = [string]$c.dir; appid = [string]$c.appid; launch = [string]$c.launch; kind = [string]$c.kind; close = @(Clean-CloseList $close); auto = $(if ($null -eq $auto) { $true } else { [bool]$auto }) }
    Games-Save (@($st.games) + $g) $st.active
    return [ordered]@{ ok = $true; message = ('Игра добавлена: ' + $n); id = $g.id }
}
function Games-Status {
    $st = Games-Load
    $out = @()
    foreach ($g in $st.games) {
        $r = Game-Rec $g
        $out += [ordered]@{ id = $r.id; name = $r.name; exe = $r.exe; close = @($r.close); auto = $r.auto; kind = $r.kind; running = (@(Game-Procs $g).Count -gt 0); launchable = [bool]($r.appid -or $r.launch) }
    }
    return [ordered]@{ games = $out; active = $st.active; admin = (Test-Admin) }
}
function Game-Add($name, $exe, $close, $auto) {
    $e = Clean-Exe $exe
    if (-not $e) { return [ordered]@{ ok = $false; message = 'Имя процесса: только буквы, цифры, точка, дефис, скобки. Например ArenaBreakoutInfinite (без .exe).' } }
    $n = ([string]$name).Trim(); if (-not $n) { $n = $e }; if ($n.Length -gt 60) { $n = $n.Substring(0, 60) }
    $st = Games-Load
    if (@($st.games | Where-Object { (G-Prop $_ 'exe') -ieq $e }).Count -gt 0) { return [ordered]@{ ok = $false; message = 'Эта игра уже в списке.' } }
    if ($st.games.Count -ge 30) { return [ordered]@{ ok = $false; message = 'В списке уже 30 игр.' } }
    $g = [ordered]@{ id = [guid]::NewGuid().ToString(); name = $n; exe = $e; dir = ''; appid = ''; launch = ''; kind = 'manual'; close = @(Clean-CloseList $close); auto = $(if ($null -eq $auto) { $true } else { [bool]$auto }) }
    Games-Save (@($st.games) + $g) $st.active
    return [ordered]@{ ok = $true; message = ('Игра добавлена: ' + $n) }
}
function Clean-CloseList($close) {
    $o = @()
    foreach ($c in @($close)) {
        $e = Clean-Exe $c
        if ($e -and ($script:ProtectedProcs -notcontains $e.ToLower()) -and ($o -notcontains $e)) { $o += $e }
        if ($o.Count -ge 20) { break }
    }
    return @($o)
}
function Game-Update($id, $close, $auto, $name) {
    $st = Games-Load; $found = $false; $new = @()
    foreach ($g in $st.games) {
        if ($g.id -eq $id) { $found = $true; $r = Game-Rec $g; if (([string]$name).Trim()) { $nn = ([string]$name).Trim(); if ($nn.Length -gt 60) { $nn = $nn.Substring(0, 60) }; $r.name = $nn }; $r.close = @(Clean-CloseList $close); $r.auto = [bool]$auto; $g = $r }
        $new += $g
    }
    if (-not $found) { return [ordered]@{ ok = $false; message = 'Игра не найдена.' } }
    Games-Save $new $st.active
    return [ordered]@{ ok = $true; message = 'Сохранено.' }
}
function Game-Remove($id) {
    $st = Games-Load
    Games-Save @($st.games | Where-Object { $_.id -ne $id }) $st.active
    if ($id -match '^[0-9a-fA-F-]{36}$') { try { Remove-Item -LiteralPath (Join-Path (Join-Path $script:AppDir 'icons') ($id + '.png')) -Force -ErrorAction SilentlyContinue } catch { } }
    return [ordered]@{ ok = $true; message = 'Игра убрана из списка.' }
}

# ---------- иконки ----------
function Game-IconFile($id) {
    if ($id -notmatch '^[0-9a-fA-F-]{36}$') { return $null }
    return (Join-Path (Join-Path $script:AppDir 'icons') ($id + '.png'))
}
function Game-IconCached($id) {
    $f = Game-IconFile $id; if (-not $f) { return $null }
    if (Test-Path -LiteralPath $f) { return ,[IO.File]::ReadAllBytes($f) }
    return $null
}
function Game-IconBytes($id) {
    $f = Game-IconFile $id; if (-not $f) { return $null }
    if (Test-Path -LiteralPath $f) { return [IO.File]::ReadAllBytes($f) }
    if ($script:MockMode) { return $null }
    if ($script:IconTried[$id] -and ((Get-Date) - $script:IconTried[$id]).TotalSeconds -lt 120) { return $null }
    $script:IconTried[$id] = Get-Date
    $st = Games-Load; $g = @($st.games | Where-Object { $_.id -eq $id }) | Select-Object -First 1
    if (-not $g) { return $null }
    # Steam: чёткая обложка из кэша библиотеки Steam (крупнее и резче значка из .exe)
    $ap = [string](G-Prop $g 'appid')
    if ($ap -match '^\d+$') {
        try {
            $sr = Get-SteamRoot
            if ($sr) {
                $lc = Join-Path $sr 'appcache\librarycache'
                $art = $null
                foreach ($nm in @('header.jpg', 'library_header.jpg', 'library_hero.jpg', 'library_600x900.jpg')) {
                    $c1 = Join-Path $lc ($ap + '_' + $nm); if (Test-Path -LiteralPath $c1) { $art = $c1; break }
                    $dd = Join-Path $lc $ap
                    if (Test-Path -LiteralPath $dd) { $c2 = @(Get-ChildItem -LiteralPath $dd -Recurse -Filter $nm -File -ErrorAction SilentlyContinue | Select-Object -First 1); if ($c2.Count) { $art = $c2[0].FullName; break } }
                }
                if ($art -and ((Get-Item -LiteralPath $art).Length -lt 3MB)) {
                    $d0 = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $d0)) { New-Item -ItemType Directory -Path $d0 -Force | Out-Null }
                    Copy-Item -LiteralPath $art -Destination $f -Force
                    return [IO.File]::ReadAllBytes($f)
                }
            }
        } catch { }
    }
    $exePath = $null
    $run = @(Get-ProcSnap | Where-Object { Under-Dir $_.Path (G-Prop $g 'dir') }) | Select-Object -First 1
    if ($run) { $exePath = $run.Path }
    elseif ((G-Prop $g 'launch') -and (Test-Path -LiteralPath (G-Prop $g 'launch'))) { $exePath = G-Prop $g 'launch' }
    elseif ((G-Prop $g 'dir') -and (Test-Path -LiteralPath (G-Prop $g 'dir'))) {
        $c = @(Get-ChildItem -LiteralPath (G-Prop $g 'dir') -Filter '*.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '(?i)unins|crash|redist|setup|vcredist|dxsetup|eac|easyanticheat|battleye|benchmark|report|helper|cef|updater|prereq' } | Sort-Object Length -Descending | Select-Object -First 1)
        if ($c.Count) { $exePath = $c[0].FullName }
    }
    if (-not $exePath) { return $null }
    try {
        Add-Type -AssemblyName System.Drawing
        # крупный значок (до 256 px) прямо из .exe: ExtractAssociatedIcon отдаёт только 32 px, отсюда «пиксели»
        try {
            if (-not ('PCDIco' -as [type])) { Add-Type -Name PCDIco -Namespace '' -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint PrivateExtractIcons(string f, int i, int cx, int cy, IntPtr[] h, int[] id, uint n, uint fl); [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);' }
            foreach ($sz in @(256, 128, 64)) {
                $hs = New-Object 'IntPtr[]' 1; $ids = New-Object 'int[]' 1
                $got = [PCDIco]::PrivateExtractIcons($exePath, 0, $sz, $sz, $hs, $ids, 1, 0)
                if ($got -ge 1 -and $hs[0] -ne [IntPtr]::Zero) {
                    $ic0 = [System.Drawing.Icon]::FromHandle($hs[0]); $b0 = $ic0.ToBitmap(); $w0 = $b0.Width
                    if ($w0 -ge 64) {
                        $d0 = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $d0)) { New-Item -ItemType Directory -Path $d0 -Force | Out-Null }
                        $b0.Save($f, [System.Drawing.Imaging.ImageFormat]::Png); $b0.Dispose(); [void][PCDIco]::DestroyIcon($hs[0])
                        return [IO.File]::ReadAllBytes($f)
                    }
                    $b0.Dispose(); [void][PCDIco]::DestroyIcon($hs[0])
                }
            }
        } catch { }
        $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
        if (-not $ic) { return $null }
        $bmp = $ic.ToBitmap()
        $d = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $ic.Dispose()
        return [IO.File]::ReadAllBytes($f)
    } catch { return $null }
}

# ---------- запуск ----------
function Game-Launch($id) {
    $st = Games-Load; $g = @($st.games | Where-Object { $_.id -eq [string]$id }) | Select-Object -First 1
    if (-not $g) { return [ordered]@{ ok = $false; message = 'Эта игра не из вашего списка.' } }
    if ($st.active) { return [ordered]@{ ok = $false; message = 'Игровой профиль уже включён для: ' + $st.active.name } }
    $appid = G-Prop $g 'appid'; $lp = G-Prop $g 'launch'
    $script:Armed[[string]$g.id] = Get-Date
    if ($script:MockMode) { if ((G-Prop $g 'exe') -and ($script:MockRunning -notcontains (G-Prop $g 'exe'))) { $script:MockRunning += (G-Prop $g 'exe') }; return [ordered]@{ ok = $true; message = ('Запускаю: ' + $g.name + ' (тестовый режим, ничего не запущено).') } }
    if ($appid -match '^\d{1,10}$') {
        if (-not (Get-Process -Name steam -ErrorAction SilentlyContinue)) { $script:Armed.Remove([string]$g.id); return [ordered]@{ ok = $false; message = 'Сначала запустите Steam и войдите в аккаунт, потом нажмите на игру.' } }
        try { Start-Process ('steam://rungameid/' + $appid) } catch { return [ordered]@{ ok = $false; message = 'Не удалось запустить через Steam.' } }
    }
    elseif ($lp -and $lp -match '\.exe$' -and (Test-Path -LiteralPath $lp)) {
        try { Start-Process -FilePath $lp -WorkingDirectory (Split-Path -Parent $lp) } catch { return [ordered]@{ ok = $false; message = 'Не удалось запустить игру.' } }
    }
    else { $script:Armed.Remove([string]$g.id); return [ordered]@{ ok = $false; message = 'Для этой игры нет способа запуска. Запустите её сами: профиль включится автоматически.' } }
    [void](Add-Event 'game' ('Запуск игры из программы: ' + $g.name) 'Профиль включится, когда игра появится в системе.')
    return [ordered]@{ ok = $true; message = ('Запускаю: ' + $g.name + '. Профиль включится, когда игра откроется.') }
}

function Game-Start($g, $procs, $isLaptop) {
    $applied = @(); $names = @(); $closed = @()
    $list = @(Get-ActionList $isLaptop)
    foreach ($id in 'power-high', 'usb-suspend', 'mouse-accel', 'gamedvr', 'gamemode', 'sticky-keys', 'mouse-speed', 'gamebar-pad', 'pcie-aspm', 'nic-power') {
        $a = $list | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $a -or $a.state -ne 'ready') { continue }   # уже настроено: не трогаем
        $r = Run-Action $id @() $isLaptop
        if ($r.ok) {
            $je = @(Journal-Get) | Where-Object { $_.action -eq $id -and $_.undoable -and -not $_.undone } | Select-Object -Last 1
            if ($je) { $applied += [string]$je.id; $names += $a.title }
        }
    }
    $prio = $false
    # приоритет процесса игры больше не трогаем: внешний доступ к процессу игры не нужен и может не понравиться античиту
    $own = (G-Prop $g 'exe'); $dir = (G-Prop $g 'dir')
    foreach ($nm in @($g.close)) {
        if (([string]$nm) -ieq $own) { continue }
        if ($script:ProtectedProcs -contains ([string]$nm).ToLower()) { continue }
        if ($script:MockMode) { $closed += $nm; continue }
        foreach ($p in @(Get-Process -Name $nm -ErrorAction SilentlyContinue)) {
            $pa = $null; try { $pa = $p.Path } catch { }
            if ($dir -and (Under-Dir $pa $dir)) { continue }
            try { [void]$p.CloseMainWindow(); $closed += $nm } catch { }
        }
    }
    $active = [ordered]@{ gameId = $g.id; name = $g.name; exe = $own; startedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); applied = @($applied); appliedNames = @($names); closed = @($closed | Select-Object -Unique); priority = $prio }
    $st = Games-Load; Games-Save $st.games $active
    $det = 'Применено только недостающее: ' + $(if ($names.Count) { $names -join '; ' } else { 'ничего (всё уже было настроено, ваши настройки не тронуты)' }) + '. Закрыто программ: ' + (@($closed | Select-Object -Unique)).Count + '. Приоритет игры: ' + $(if ($prio) { 'высокий' } else { 'не менялся' }) + '.'
    [void](Add-Event 'game' ('Игра запущена: ' + $g.name + ', профиль включён') $det)
    try { Sess-Begin $g } catch { }
}
function Game-Stop($active) {
    try { [void](Sess-End 'игра закрыта') } catch { }
    $undone = 0
    foreach ($jid in @($active.applied)) { $r = Run-Undo ([string]$jid); if ($r.ok) { $undone++ } }
    $st = Games-Load; Games-Save $st.games $null
    [void](Add-Event 'game' ('Игра закрыта: ' + $active.name + ', настройки возвращены') ('Возвращено настроек: ' + $undone + ' из ' + @($active.applied).Count + '. Возвращается только то, что включила программа. Закрытые фоновые программы программа не открывает заново.'))
}
function Game-Tick($isLaptop) {
    $st = Games-Load
    if ($st.active) {
        $ag = @($st.games | Where-Object { $_.id -eq $st.active.gameId }) | Select-Object -First 1
        if (-not $ag) { $ag = [pscustomobject]@{ exe = [string]$st.active.exe; dir = '' } }
        if (@(Game-Procs $ag).Count -eq 0) { Game-Stop $st.active }
        return
    }
    # игры Steam из списка найденных: если такая запущена, а плитки нет, добавляем плитку сами
    if (-not $script:MockMode -and (Get-SteamRoot)) {
        foreach ($c in @(Games-Discover $false | Where-Object { $_.kind -eq 'steam' })) {
            $have = $false; foreach ($g in $st.games) { if ((G-Prop $g 'appid') -eq $c.appid) { $have = $true } }
            if ($have) { continue }
            if (@(Get-ProcSnap | Where-Object { Under-Dir $_.Path $c.dir }).Count -gt 0) { [void](Game-Add-Found $c.key @() $true); $st = Games-Load }
        }
    }
    foreach ($g in $st.games) {
        $armed = $script:Armed.ContainsKey([string]$g.id) -and (((Get-Date) - $script:Armed[[string]$g.id]).TotalMinutes -lt 10)
        if (-not [bool]$g.auto -and -not $armed) { continue }
        $pr = @(Game-Procs $g)
        if ($pr.Count -gt 0) { Game-Learn-Exe $g $pr; $script:Armed.Remove([string]$g.id); Game-Start $g $pr $isLaptop; return }
    }
}
