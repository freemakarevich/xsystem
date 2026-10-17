# Windows PowerShell 5.1 / PowerShell 7. UTF-8 without BOM for irm | iex.
param([switch]$LibraryOnly)

function Get-MKHGames {
    [ordered]@{
        MKX = @(
            'malcolm-prod-chat.wbplay.com'
            'malcolm-prod-swarm.wbplay.com'
            'malcolm-prod-event.wbplay.com'
        )
        MK1 = @(
            'k1-api.wbagora.com'
            'prod-network-api.wbagora.com'
            'account.wbgames.com'
            'metallica-api.wbagora.com'
        )
        MK11 = @(
            'mk11-api.wbagora.com'
            'event.wbinsights.com'
            'us-east-1-mk11-realtime-1.wbagora.com'
            'us-east-1-mk11-realtime-2.wbagora.com'
            'us-east-1-mk11-realtime-3.wbagora.com'
            'us-east-1-mk11-realtime-4.wbagora.com'
            'us-east-1-mk11-realtime-5.wbagora.com'
            'us-east-1-mk11-realtime-6.wbagora.com'
            'us-east-1-mk11-realtime-7.wbagora.com'
            'us-east-1-mk11-realtime-8.wbagora.com'
        )
    }
}

function Get-MKHHash {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-MKHRegularPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Ссылки/reparse points не поддерживаются: $Path"
    }
}

function Read-MKHDocument {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    $offset = 0
    $encoding = $null
    if ($Bytes.Length -ge 4 -and (
        ($Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) -or
        ($Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255))) {
        throw 'Неожиданная кодировка UTF-32 в hosts; файл не изменён.'
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $offset = 3
        $encoding = [Text.UTF8Encoding]::new($false, $true)
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        $offset = 2
        $encoding = [Text.UnicodeEncoding]::new($false, $false, $true)
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $offset = 2
        $encoding = [Text.UnicodeEncoding]::new($true, $false, $true)
    } else {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        try { $null = $encoding.GetString($Bytes) }
        catch {
            # Latin-1 preserves arbitrary legacy bytes; all new hosts text is ASCII.
            $encoding = [Text.Encoding]::GetEncoding(28591)
        }
    }
    $content = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    if ($content.Contains([string][char]0)) { throw 'Нулевые символы в hosts; файл не изменён.' }
    $preamble = New-Object byte[] $offset
    if ($offset) { [Array]::Copy($Bytes, $preamble, $offset) }
    $eol = [regex]::Match($content, '\r\n|\n|\r').Value
    if (-not $eol) { $eol = "`r`n" }
    [pscustomobject]@{ Text = $content; Encoding = $encoding; Preamble = $preamble; NewLine = $eol }
}

function ConvertTo-MKHBytes {
    param($Document, [AllowEmptyString()][string]$Text)
    $body = $Document.Encoding.GetBytes($Text)
    $bytes = New-Object byte[] ($Document.Preamble.Length + $body.Length)
    [Array]::Copy($Document.Preamble, 0, $bytes, 0, $Document.Preamble.Length)
    [Array]::Copy($body, 0, $bytes, $Document.Preamble.Length, $body.Length)
    return ,$bytes
}

function Remove-MKHBlock {
    param([AllowEmptyString()][string]$Text)
    $start = '# BEGIN MK-HOSTS-MANAGER v1'
    $end = '# END MK-HOSTS-MANAGER v1'
    $inside = $false
    $builder = [Text.StringBuilder]::new()
    foreach ($match in [regex]::Matches($Text, '[^\r\n]*(?:\r\n|\r|\n|$)')) {
        if (-not $match.Length) { continue }
        $line = $match.Value.Trim()
        if ($line -eq $start) {
            if ($inside) { throw 'Вложенный блок MK hosts.' }
            $inside = $true
        } elseif ($line -eq $end) {
            if (-not $inside) { throw 'Повреждён блок MK hosts.' }
            $inside = $false
        } elseif (-not $inside) { $null = $builder.Append($match.Value) }
    }
    if ($inside) { throw 'Не найден конец блока MK hosts.' }
    return $builder.ToString()
}

function Get-MKHBlockGames {
    param([AllowEmptyString()][string]$Text)
    $null = Remove-MKHBlock $Text
    $catalog = Get-MKHGames
    $found = @{}
    $inside = $false
    foreach ($line in ($Text -split '\r\n|\r|\n')) {
        if ($line.Trim() -eq '# BEGIN MK-HOSTS-MANAGER v1') { $inside = $true; continue }
        if ($line.Trim() -eq '# END MK-HOSTS-MANAGER v1') { $inside = $false; continue }
        if (-not $inside) { continue }
        foreach ($game in $catalog.Keys) {
            if ($line.Trim() -eq ('# ' + $game)) { $found[$game] = $true }
            $names = ($line -split '#', 2)[0].Trim() -split '\s+'
            foreach ($domain in $catalog[$game]) {
                if ($names -contains $domain) { $found[$game] = $true }
            }
        }
    }
    return @($catalog.Keys | Where-Object { $found.ContainsKey($_) })
}

function Get-MKHMapping {
    param([AllowEmptyString()][string]$Text)
    foreach ($line in ($Text -split '\r\n|\r|\n')) {
        $fields = ($line -split '#', 2)[0].Trim() -split '\s+'
        $address = $null
        if ($fields.Count -lt 2 -or -not [Net.IPAddress]::TryParse($fields[0], [ref]$address)) { continue }
        foreach ($name in $fields[1..($fields.Count - 1)]) {
            [pscustomobject]@{ IP = $fields[0]; Name = $name; Key = $name.TrimEnd('.').ToLowerInvariant() }
        }
    }
}

function Restore-MKHText {
    param([AllowEmptyString()][string]$Current, [AllowEmptyString()][string]$Original,
        [string[]]$Games, [string]$NewLine)
    $outside = Remove-MKHBlock $Current
    $baseline = Remove-MKHBlock $Original
    if (-not $Games.Count) { return $outside }
    $expected = Remove-MKHBlock (New-MKHText $baseline $Games $NewLine)
    # An edited managed block does not prevent exact restoration of untouched surroundings.
    if ($outside -ceq $expected) { return $baseline }
    $catalog = Get-MKHGames
    $owned = @{}
    foreach ($game in $Games) { foreach ($domain in $catalog[$game]) { $owned[$domain] = $true } }
    $existing = @{}
    foreach ($mapping in (Get-MKHMapping $outside)) { $existing[$mapping.Key] = $true }
    $builder = [Text.StringBuilder]::new($outside)
    foreach ($mapping in (Get-MKHMapping $baseline)) {
        if (-not $owned.ContainsKey($mapping.Key) -or $existing.ContainsKey($mapping.Key)) { continue }
        if ($builder.Length -and $builder[$builder.Length - 1] -notin @("`n", "`r")) { $null = $builder.Append($NewLine) }
        $null = $builder.Append($mapping.IP + ' ' + $mapping.Name + $NewLine)
        # Do not restore a second stale/conflicting mapping for the same name.
        $existing[$mapping.Key] = $true
    }
    return $builder.ToString()
}

function New-MKHText {
    param([AllowEmptyString()][string]$Text, [string[]]$Games, [string]$NewLine)
    $catalog = Get-MKHGames
    $domains = @{}
    foreach ($game in $Games) {
        if (-not $catalog.Contains($game)) { throw "Неизвестная игра: $game" }
        foreach ($domain in $catalog[$game]) { $domains[$domain] = $true }
    }
    if (-not $domains.Count) { throw 'Пустой список игр.' }
    $builder = [Text.StringBuilder]::new()
    foreach ($match in [regex]::Matches((Remove-MKHBlock $Text), '[^\r\n]*(?:\r\n|\r|\n|$)')) {
        if (-not $match.Length) { continue }
        $raw = $match.Value
        $line = $raw.TrimEnd([char[]]"`r`n")
        $ending = $raw.Substring($line.Length)
        $parts = $line -split '#', 2
        $mapping = [regex]::Match($parts[0], '^(\s*)(\S+)(\s+)(.*)$')
        $parsedAddress = $null
        if (-not $mapping.Success -or -not [Net.IPAddress]::TryParse($mapping.Groups[2].Value, [ref]$parsedAddress)) {
            $null = $builder.Append($raw); continue
        }
        $names = @([regex]::Matches($mapping.Groups[4].Value, '\S+') | ForEach-Object { $_.Value })
        $remaining = @($names | Where-Object { -not $domains.ContainsKey($_.TrimEnd('.')) })
        if ($remaining.Count -eq $names.Count) { $null = $builder.Append($raw); continue }
        $comment = if ($parts.Count -eq 2) { '#' + $parts[1] } else { '' }
        if ($remaining.Count) {
            $replacement = $mapping.Groups[1].Value + $mapping.Groups[2].Value +
                $mapping.Groups[3].Value + ($remaining -join ' ')
            if ($comment) { $replacement += ' ' + $comment }
            $null = $builder.Append($replacement + $ending)
        } elseif ($comment) { $null = $builder.Append($mapping.Groups[1].Value + $comment + $ending) }
    }
    if ($builder.Length -and $builder[$builder.Length - 1] -ne "`n" -and $builder[$builder.Length - 1] -ne "`r") {
        $null = $builder.Append($NewLine)
    }
    $null = $builder.Append('# BEGIN MK-HOSTS-MANAGER v1' + $NewLine)
    foreach ($game in $catalog.Keys) {
        if ($Games -notcontains $game) { continue }
        $null = $builder.Append('# ' + $game + $NewLine)
        foreach ($domain in $catalog[$game]) {
            $null = $builder.Append('216.9.224.250 ' + $domain + $NewLine)
        }
    }
    $null = $builder.Append('# END MK-HOSTS-MANAGER v1' + $NewLine)
    return $builder.ToString()
}

function Write-MKHState {
    param([string]$Path, $State)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 8
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Write-MKHHosts {
    param([string]$Path, [AllowEmptyCollection()][byte[]]$Bytes, [string]$ExpectedHash)
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('mkhosts-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ((Get-MKHHash ([IO.File]::ReadAllBytes($Path))) -ne $ExpectedHash) {
            throw 'hosts изменён другой программой во время операции. Повтори после проверки файла.'
        }
        # Replace preserves the destination ACL and avoids a partially written hosts file.
        [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-MKHChange {
    param([string]$HostsPath, [string]$StateDirectory, [string[]]$Games, [switch]$Restore)
    $HostsPath = [IO.Path]::GetFullPath($HostsPath)
    Assert-MKHRegularPath $HostsPath
    Assert-MKHRegularPath $StateDirectory
    $statePath = Join-Path $StateDirectory 'state.json'
    $currentBytes = [IO.File]::ReadAllBytes($HostsPath)
    $currentHash = Get-MKHHash $currentBytes
    $document = Read-MKHDocument $currentBytes
    $outside = Remove-MKHBlock $document.Text
    $blockGames = @(Get-MKHBlockGames $document.Text)
    $hasBlock = $outside -cne $document.Text
    $state = $null
    if ([IO.File]::Exists($statePath)) {
        Assert-MKHRegularPath $statePath
        $state = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($state.Version -ne 1 -or $state.HostsPath -ine $HostsPath -or
            $state.BackupFile -notmatch '^hosts-original-[a-f0-9]{32}\.bak$') {
            throw "Неподходящий файл состояния: $statePath"
        }
        if ($state.Pending -and $currentHash -eq $state.Pending.Hash) {
            $state.LastHash = $state.Pending.Hash
            $state.Games = @($state.Pending.Games)
            $state.Active = $state.Pending.Active
            $state.Pending = $null
            Write-MKHState $statePath $state
        }
    }
    if ($Restore -and (-not $state -or -not $state.Active) -and -not $hasBlock) {
        return [pscustomobject]@{ Changed = $false; Message = 'Нет активных изменений этого скрипта для восстановления.'; Backup = $null }
    }
    if ($state -and $state.Active) {
        $backupPath = Join-Path $StateDirectory $state.BackupFile
        Assert-MKHRegularPath $backupPath
        $originalBytes = [IO.File]::ReadAllBytes($backupPath)
        if ((Get-MKHHash $originalBytes) -ne $state.OriginalHash) { throw 'Исходная резервная копия повреждена. hosts не изменён.' }
    } else {
        $state = [pscustomobject]@{
            Version = 1; HostsPath = $HostsPath
            BackupFile = ('hosts-original-' + [guid]::NewGuid().ToString('N') + '.bak')
            OriginalHash = $currentHash; LastHash = $currentHash
            Games = @($blockGames); Active = $true; Pending = $null
            CreatedAt = [DateTimeOffset]::Now.ToString('o')
        }
        $backupPath = Join-Path $StateDirectory $state.BackupFile
        [IO.File]::WriteAllBytes($backupPath, $currentBytes)
        $originalBytes = $currentBytes
    }
    if ($Restore) {
        $originalDocument = Read-MKHDocument $originalBytes
        $targetText = Restore-MKHText $document.Text $originalDocument.Text @($state.Games) $document.NewLine
        $targetBytes = ConvertTo-MKHBytes $document $targetText
        if ($targetText -ceq $originalDocument.Text) { $targetBytes = $originalBytes }
        $targetGames = @()
        $message = 'Блок MK удалён, прежние записи MK восстановлены; посторонние ручные правки сохранены.'
    } else {
        $catalog = Get-MKHGames
        foreach ($game in $Games) { if (-not $catalog.Contains($game)) { throw "Неизвестная игра: $game" } }
        if (-not $Games.Count) { throw 'Не выбрана игра.' }
        $targetGames = @($catalog.Keys | Where-Object { @($state.Games) -contains $_ -or $blockGames -contains $_ -or $Games -contains $_ })
        # Work on the current file, never erase unrelated edits using an old snapshot.
        $targetText = New-MKHText $document.Text $targetGames $document.NewLine
        $targetBytes = ConvertTo-MKHBytes $document $targetText
        $message = 'Настроены: ' + ($targetGames -join ', ') + '. Перезапусти игру.'
    }
    $targetHash = Get-MKHHash $targetBytes
    if ($targetHash -eq $currentHash) {
        $state.LastHash = $currentHash
        $state.Games = @($targetGames)
        $state.Active = -not $Restore
        $state.Pending = $null
        Write-MKHState $statePath $state
        return [pscustomobject]@{ Changed = $false; Message = $message; Backup = $backupPath }
    }
    $operationBackup = Join-Path $StateDirectory ('hosts-before-' + [guid]::NewGuid().ToString('N') + '.bak')
    [IO.File]::WriteAllBytes($operationBackup, $currentBytes)
    # Write-ahead state lets the next run recover after an interrupted atomic replacement.
    $state.Pending = [pscustomobject]@{ Hash = $targetHash; Games = @($targetGames); Active = (-not $Restore) }
    Write-MKHState $statePath $state
    Write-MKHHosts $HostsPath $targetBytes $currentHash
    $state.LastHash = $targetHash
    $state.Games = @($targetGames)
    $state.Active = -not $Restore
    $state.Pending = $null
    Write-MKHState $statePath $state
    [pscustomobject]@{ Changed = $true; Message = $message; Backup = $operationBackup }
}

function Test-MKHAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Initialize-MKHStorage {
    param([string]$Path)
    if ([IO.Directory]::Exists($Path)) {
        Assert-MKHRegularPath $Path
        $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18', 'S-1-5-32-544')) {
            throw "Каталог резервных копий уже существует с неподходящим владельцем: $Path"
        }
    } else { $null = [IO.Directory]::CreateDirectory($Path) }
    # Backups and transaction state must not be writable by ordinary local users.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid),
            [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Start-MKHMenu {
    $ErrorActionPreference = 'Stop'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Write-Host 'Этот скрипт предназначен только для Windows.' -ForegroundColor Red
        return
    }
    if (-not (Test-MKHAdministrator)) {
        Write-Host 'Нужен PowerShell, запущенный от имени администратора.' -ForegroundColor Yellow
        Write-Host 'Закрой это окно, открой PowerShell через «Запуск от имени администратора» и повтори команду.'
        return
    }
    $systemFolder = Join-Path $env:windir 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $systemFolder = Join-Path $env:windir 'Sysnative'
    }
    $hostsFile = Join-Path $systemFolder 'drivers\etc\hosts'
    $storage = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'MKHostsManager'
    Write-Host ''
    Write-Host 'Mortal Kombat — настройка hosts' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '1 — Разблокировать все: MKX, MK11, MK1'
    Write-Host '2 — Разблокировать MKX'
    Write-Host '3 — Разблокировать MK11'
    Write-Host '4 — Разблокировать MK1'
    Write-Host '5 — Убрать настройки MK (сохранить остальные записи)'
    Write-Host '0 — Выход'
    do { $choice = (Read-Host 'Выбери пункт (0–5)').Trim() } while ($choice -notmatch '^[0-5]$')
    if ($choice -eq '0') { return }
    $mutex = [Threading.Mutex]::new($false, 'Global\MKHostsManagerV1')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Другой экземпляр скрипта уже изменяет hosts.' }
        Initialize-MKHStorage $storage
        $selected = switch ($choice) {
            '1' { @('MKX', 'MK11', 'MK1') }
            '2' { @('MKX') }
            '3' { @('MK11') }
            '4' { @('MK1') }
            '5' { @() }
        }
        $result = Invoke-MKHChange -HostsPath $hostsFile -StateDirectory $storage -Games @($selected) -Restore:($choice -eq '5')
        Write-Host $result.Message -ForegroundColor Green
        if ($result.Backup) { Write-Host ('Резервная копия: ' + $result.Backup) }
        if ($result.Changed) {
            try { Clear-DnsClientCache -ErrorAction Stop; Write-Host 'DNS-кэш очищен.' }
            catch { Write-Warning 'hosts сохранён, но очистить DNS-кэш не удалось. Выполни ipconfig /flushdns.' }
        }
    } catch {
        Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Не удаляй резервную копию. Скрипт не отключает защиту и не меняет права файла hosts.'
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if (-not $LibraryOnly) { Start-MKHMenu }
