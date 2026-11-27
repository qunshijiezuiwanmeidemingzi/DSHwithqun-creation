param(
    [string]$Mode = 'convert',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths
)

$ErrorActionPreference = 'Continue'
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ff    = Join-Path $root 'tools\ffmpeg.exe'
$CARD  = 'F:\'

if (-not (Test-Path -LiteralPath $ff)) {
    Write-Host ''
    Write-Host '  缺少 tools\ffmpeg.exe —— 检测和转码都要靠它。' -ForegroundColor Red
    Write-Host '  请把 ffmpeg.exe 放到本脚本同级的 tools 文件夹里，下载地址见 README。' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$script:okCount   = 0
$script:convCount = 0
$script:copyCount = 0
$script:failCount = 0
$script:failed    = New-Object System.Collections.Generic.List[string]

$exts = @('.mp3','.m4a','.m4b','.aac','.flac','.wav','.wma','.ape','.alac','.ogg','.oga','.opus','.aif','.aiff','.dsf','.dff','.mp4','.mkv','.webm','.avi','.ts')

function Line($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head($t) {
    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('-' * 64) -ForegroundColor DarkGray
}

function Get-AudioInfo([string]$File) {
    $text = ((& $ff -hide_banner -i $File 2>&1) | ForEach-Object { "$_" }) -join "`n"
    $o = New-Object psobject -Property @{
        Container = '?'; Codec = '?'; Rate = 0; Layout = ''; Kbps = 0; Duration = ''; HasAudio = $false
    }
    if ($text -match 'Input #0,\s*(.+?),\s*from')  { $o.Container = $Matches[1].Trim() }
    if ($text -match 'Audio:\s*([A-Za-z0-9_]+)(?:\s*\([^)]*\))*,\s*(\d+) Hz,\s*([^,\r\n]+)') {
        $o.HasAudio = $true
        $o.Codec    = $Matches[1]
        $o.Rate     = [int]$Matches[2]
        $o.Layout   = $Matches[3].Trim()
    }
    if ($text -match 'Audio:[^\r\n]*?(\d+)\s*kb/s')  { $o.Kbps = [int]$Matches[1] }
    if ($text -match 'Duration:\s*(\d+:\d+:\d+(?:\.\d+)?)') { $o.Duration = $Matches[1] }
    return $o
}

function Get-TagInfo([string]$File) {
    $b = New-Object byte[] 10
    try {
        $fs = [IO.File]::OpenRead($File)
        try { $null = $fs.Read($b, 0, 10) } finally { $fs.Dispose() }
    } catch { return @{ Id3 = $false; Size = 0 } }
    if ($b[0] -ne 0x49 -or $b[1] -ne 0x44 -or $b[2] -ne 0x33) { return @{ Id3 = $false; Size = 0 } }
    $size = ([int]$b[6] -shl 21) -bor ([int]$b[7] -shl 14) -bor ([int]$b[8] -shl 7) -bor ([int]$b[9])
    return @{ Id3 = $true; Size = $size }
}

function Test-Compatible($info) {
    if (-not $info.HasAudio)         { return $false }
    if ($info.Codec -ne 'mp3')       { return $false }
    if ($info.Rate -ne 44100)        { return $false }
    if ($info.Kbps -lt 64)           { return $false }
    return $true
}

function Find-Files([string[]]$items) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in $items) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $p = $p.Trim('"')
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $exts -contains $_.Extension.ToLower() -and
                    $_.DirectoryName -notmatch '已转MP3'
                } |
                ForEach-Object { $list.Add($_.FullName) }
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $list.Add((Resolve-Path -LiteralPath $p).Path)
        } else {
            Line ('  找不到: ' + $p) 'Yellow'
        }
    }
    return ($list | Select-Object -Unique)
}

function Get-OutDir([string]$File) {
    if ($Mode -eq 'card') { return $CARD }
    return (Join-Path (Split-Path -Parent $File) '已转MP3')
}

function Format-Size([long]$n) { return ('{0:N2} MB' -f ($n / 1MB)) }

function Convert-One([string]$File, [int]$idx, [int]$total) {
    $name = Split-Path -Leaf $File
    $info = Get-AudioInfo $File
    $tag  = Get-TagInfo $File

    $needRecode = -not (Test-Compatible $info)
    $tagBig     = $tag.Size -gt 200000

    if ($tag.Id3) { $tagText = '标签 ' + [math]::Round($tag.Size / 1024) + 'KB' } else { $tagText = '无ID3' }
    $fmt = ('{0} | {1} {2}Hz {3}' -f $info.Container, $info.Codec, $info.Rate, $tagText)
    if (-not $info.HasAudio) { $fmt = ('{0} | 读不出音频流 {1}' -f $info.Container, $tagText) }

    Line ("[{0}/{1}] {2}" -f $idx, $total, $name) 'White'
    Line ("        " + $fmt) 'DarkGray'

    $why = @()
    if (-not $info.HasAudio) { $why += '文件损坏或不是音频' }
    elseif ($info.Codec -ne 'mp3') { $why += ('编码是 ' + $info.Codec + '，不是 MP3') }
    if ($info.HasAudio -and $info.Rate -ne 44100) { $why += ('采样率 ' + $info.Rate + 'Hz，不是 44100') }
    if ($info.HasAudio -and $info.Kbps -lt 64)    { $why += '码率读不出（多半是 VBR）' }
    if ($tagBig) { $why += ('内嵌封面/标签 ' + [math]::Round($tag.Size / 1024) + 'KB 太大') }

    if ($why.Count -eq 0) {
        $script:copyCount++
        Line '        本来就是兼容 MP3，只清标签（无损）' 'Green'
    } elseif ($needRecode) {
        $script:convCount++
        Line ('        需要转码 -> ' + ($why -join '；')) 'Yellow'
    } else {
        $script:copyCount++
        Line ('        只去掉多余标签（无损） -> ' + ($why -join '；')) 'Yellow'
    }

    if ($Mode -eq 'check') { return }

    $outDir = Get-OutDir $File
    if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
    $base = [IO.Path]::GetFileNameWithoutExtension($File)
    $out  = Join-Path $outDir ($base + '.mp3')

    $ffArgs = @('-y', '-v', 'error', '-i', $File, '-map', '0:a:0', '-vn', '-map_metadata', '-1',
                '-id3v2_version', '3', '-write_id3v1', '0', '-metadata', ('title=' + $base))
    if ($needRecode) {
        $ffArgs += @('-c:a', 'libmp3lame', '-b:a', '192k', '-ar', '44100', '-ac', '2')
    } else {
        $ffArgs += @('-c:a', 'copy')
    }
    $ffArgs += $out

    $null = & $ff @ffArgs 2>&1
    if ((Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 20000)) {
        $script:okCount++
        Line ('        完成 -> ' + $out + '  ' + (Format-Size (Get-Item -LiteralPath $out).Length)) 'Green'
    } else {
        $script:failCount++
        $script:failed.Add($name)
        Line '        失败：文件可能损坏或受保护' 'Red'
    }
}

# ---------------- main ----------------
if (-not $Paths -or $Paths.Count -eq 0) {
    Head '使用方法'
    Line '  把歌曲文件（或整个文件夹）拖到这个 .bat 文件上。'
    Line ''
    Line '  · 好歌一键转MP3.bat   -> 在原文件夹里生成「已转MP3」子文件夹'
    Line '  · 检查能不能播.bat    -> 只检查，不转换'
    Line '  · 转换并拷进TF卡.bat  -> 转好后直接放进 F: 卡根目录'
    Line ''
    exit
}

if ($Mode -eq 'card') {
    if (-not (Test-Path $CARD)) { Line '错误：没找到 F: 盘，请先插卡。' 'Red'; exit 1 }
    $v = Get-Volume -DriveLetter F -ErrorAction SilentlyContinue
    if ($v -and $v.FileSystem -ne 'FAT32') {
        Line ('注意：F: 现在不是 FAT32 而是 ' + $v.FileSystem + '，这类播放器通常只认 FAT32。') 'Yellow'
    }
    foreach ($ix in @('FILE.IDX', 'MIDX')) {
        $p = Join-Path $CARD $ix
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Line ('已清掉旧索引 ' + $ix) 'DarkGray' }
    }
}

$files = @(Find-Files $Paths)
$total = $files.Count
if ($total -eq 0) { Line '没有找到可处理的音频文件。' 'Yellow'; exit }

Head ('共 ' + $total + ' 个文件')
$i = 0
foreach ($f in $files) {
    $i++
    Convert-One $f $i $total
}

Write-Host ''
Write-Host ('-' * 64) -ForegroundColor DarkGray
if ($Mode -eq 'check') {
    Line ('检查完毕：共 ' + $total + ' 个，其中 ' + $script:convCount + ' 个必须转码，' + $script:copyCount + ' 个可直接用。') 'Cyan'
} else {
    Line '处理完毕' 'Cyan'
    Line ('  需要转码: ' + $script:convCount + '    直接处理: ' + $script:copyCount + '    成功: ' + $script:okCount + '    失败: ' + $script:failCount) 'White'
    if ($script:failCount -gt 0) { Line ('  失败文件: ' + ($script:failed -join '、')) 'Red' }
    if ($Mode -eq 'convert') { Line '  结果在源文件旁边的「已转MP3」文件夹里。' 'Gray' }
    if ($Mode -eq 'card')    { Line '  已放进 F: 卡根目录，弹出卡插回播放器即可。' 'Gray' }
}
Line ''
