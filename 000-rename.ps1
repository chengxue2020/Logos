param([string]$m3uPath = "000-test.m3u")

# ===== 可调整参数 =====
$timeoutSeconds = 5      # 超时时间（秒）
$maxRetries = 1          # 重试次数
$retryDelaySeconds = 1   # 重试间隔（秒）
$maxFilenameLength = 200 # 最大文件名长度（Windows限制255，留余量）
# ====================

if (-not (Test-Path $m3uPath)) {
    Write-Host "错误：找不到文件 $m3uPath" -ForegroundColor Red
    pause
    exit 1
}

$fileCounter = @{}
$failedItems = @()

function Get-UniqueFileName {
    param([string]$baseName, [string]$extension)
    $originalFileName = $baseName + $extension
    $fileName = $originalFileName
    if ($fileCounter.ContainsKey($originalFileName)) {
        $fileCounter[$originalFileName]++
        $counter = $fileCounter[$originalFileName]
        $fileName = $baseName + "_$counter" + $extension
        while ($fileCounter.ContainsKey($fileName) -or (Test-Path $fileName)) {
            $counter++
            $fileName = $baseName + "_$counter" + $extension
        }
        $fileCounter[$fileName] = 0
    } else {
        if (Test-Path $originalFileName) {
            $fileCounter[$originalFileName] = 1
            $fileName = $baseName + "_1" + $extension
            $fileCounter[$fileName] = 0
        } else {
            $fileCounter[$originalFileName] = 0
        }
    }
    return $fileName
}

# 函数：完全清理文件名中的非法字符
function Sanitize-Filename {
    param([string]$name)
    
    if ([string]::IsNullOrWhiteSpace($name)) {
        return "unnamed_channel"
    }
    
    # 1. 移除控制字符（ASCII 0-31）
    $safeName = $name -replace '[\x00-\x1f]', ''
    
    # 2. 替换Windows非法字符为下划线
    # 非法字符：\ / : * ? " < > |
    $invalidChars = '[\\/:*?"<>|]'
    $safeName = $safeName -replace $invalidChars, '_'
    
    # 3. 移除其他可能有问题的字符（可选）
    # 保留字母、数字、中文、空格、点号、下划线、连字符
    # 这行会删除其他特殊字符，如果需要更严格可以取消注释
    # $safeName = $safeName -replace '[^\p{L}\p{N}\s\.\-_]', '_'
    
    # 4. 处理多个连续下划线（将 ___ 替换为 _）
    $safeName = $safeName -replace '_{2,}', '_'
    
    # 5. 移除首尾的空格、点号、下划线
    $safeName = $safeName.Trim(' ', '.', '_')
    
    # 6. 如果清理后为空，使用默认名称
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = "unnamed_channel"
    }
    
    # 7. 处理Windows保留设备名
    $reservedNames = @(
        'CON', 'PRN', 'AUX', 'NUL',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )
    if ($safeName -in $reservedNames) {
        $safeName = "_$safeName"
    }
    
    # 8. 处理以点号或空格结尾的情况
    if ($safeName -match '[.\s]$') {
        $safeName = $safeName -replace '[.\s]+$', ''
    }
    
    # 9. 限制文件名长度
    if ($safeName.Length -gt $maxFilenameLength) {
        $safeName = $safeName.Substring(0, $maxFilenameLength)
        # 避免截断后以空格或点号结尾
        $safeName = $safeName.Trim(' ', '.', '_')
    }
    
    return $safeName
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "      M3U 图片批量下载工具" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "超时设置: ${timeoutSeconds}秒" -ForegroundColor Yellow
Write-Host "重试次数: ${maxRetries}次" -ForegroundColor Yellow
Write-Host "处理文件: $m3uPath" -ForegroundColor Yellow
Write-Host ""

$content = Get-Content $m3uPath -Encoding UTF8
$totalCount = 0
$successCount = 0
$failCount = 0
$duplicateCount = 0
$warningCount = 0
$startTime = Get-Date

foreach ($line in $content) {
    if ($line -match '#EXTINF.*tvg-name="([^"]*)".*tvg-logo="([^"]*)"') {
        $totalCount++
        $channelName = $matches[1]
        $logoUrl = $matches[2]
        
        # 记录原始名称（用于日志）
        $originalName = $channelName
        
        # 清理文件名
        $safeName = Sanitize-Filename -name $channelName
        
        # 检查是否被修改
        if ($originalName -ne $safeName -and $originalName -notmatch '^[\\/:*?"<>|]') {
            $warningCount++
            Write-Host "  [注意] 文件名已清理: $originalName -> $safeName" -ForegroundColor Yellow
        }
        
        # 获取文件扩展名
        $extension = [System.IO.Path]::GetExtension($logoUrl.Split('?')[0])
        if ([string]::IsNullOrEmpty($extension)) { 
            $extension = ".png" 
        }
        
        # 获取不重复的文件名
        $fileName = Get-UniqueFileName -baseName $safeName -extension $extension
        if ($fileName -ne ($safeName + $extension)) {
            $duplicateCount++
        }
        
        Write-Host "[$totalCount] 下载: $safeName" -ForegroundColor White
        
        $retryCount = 0
        $downloaded = $false
        
        while ($retryCount -le $maxRetries -and -not $downloaded) {
            try {
                if ($retryCount -gt 0) {
                    Write-Host "    重试 $retryCount/$maxRetries..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $retryDelaySeconds
                }
                
                Invoke-WebRequest -Uri $logoUrl -OutFile $fileName -TimeoutSec $timeoutSeconds -UseBasicParsing
                $downloaded = $true
                Write-Host "  [成功] $fileName" -ForegroundColor Green
                $successCount++
                
            } catch {
                $retryCount++
                if ($retryCount -gt $maxRetries) {
                    $errorMsg = $_.Exception.Message
                    Write-Host "  [失败] $safeName" -ForegroundColor Red
                    Write-Host "    原因: $errorMsg" -ForegroundColor Red
                    $failCount++
                    
                    $failedItems += @{
                        ChannelName = $originalName
                        CleanName = $safeName
                        LogoUrl = $logoUrl
                        ErrorType = "下载失败"
                        ErrorMessage = $errorMsg
                        TargetFile = $fileName
                    }
                }
            }
        }
    }
}

$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "           下载完成" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "统计信息:" -ForegroundColor Yellow
Write-Host "  总频道数: $totalCount" -ForegroundColor White
Write-Host "  成功下载: $successCount" -ForegroundColor Green
Write-Host "  下载失败: $failCount" -ForegroundColor Red
if ($duplicateCount -gt 0) {
    Write-Host "  重命名处理: $duplicateCount (添加序号)" -ForegroundColor Yellow
}
if ($warningCount -gt 0) {
    Write-Host "  文件名清理: $warningCount (移除了非法字符)" -ForegroundColor Yellow
}
Write-Host "  总耗时: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host ""

if ($failCount -gt 0 -and $failedItems.Count -gt 0) {
    Write-Host "失败详情:" -ForegroundColor Red
    Write-Host "----------------------------------------" -ForegroundColor Red
    foreach ($item in $failedItems) {
        Write-Host "原始频道: $($item.ChannelName)" -ForegroundColor Red
        if ($item.ChannelName -ne $item.CleanName) {
            Write-Host "  清理后: $($item.CleanName)" -ForegroundColor Gray
        }
        Write-Host "  图片URL: $($item.LogoUrl)" -ForegroundColor Gray
        Write-Host "  错误原因: $($item.ErrorMessage)" -ForegroundColor Yellow
        Write-Host ""
    }
}

Write-Host ""
pause