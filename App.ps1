param([switch]$Background, [switch]$ValidateUi, [string]$RenderUi, [double]$UiScale = 1)
. "$PSScriptRoot\Common.ps1"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2)
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$mutexName = if ($ValidateUi) { 'Local\XidianCampusLoginUiTest' + $PID } else { 'Local\XidianCampusLoginApp' }
$appMutex = [Threading.Mutex]::new($false,$mutexName)
$script:OwnMutex = $false
try { $script:OwnMutex = $appMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:OwnMutex = $true }
if (!$script:OwnMutex) {
    $request = if ($Background) { 'hide.request' } else { 'open.request' }
    [IO.File]::WriteAllText((Join-Path $script:DataRoot $request),'')
    $appMutex.Dispose(); exit
}
$settings = if ($ValidateUi) { [pscustomobject]@{ ssids=@('stu-xdwlan'); username=''; protectedPassword=''; enabled=$true; showTaskbarIcon=$true; showTrayIcon=$true } } else { Read-Settings }
$script:MayExit = $false; $script:LastPopup = ''; $script:LastWatchdog = [DateTimeOffset]::MinValue
$startupPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'XidianCampusLogin.lnk'
$runtime = Join-Path $PSHOME 'pwsh.exe'
function Start-Monitor {
    $stopPath = Join-Path $script:DataRoot 'stop.request'
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath }
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSScriptRoot + '\Monitor.ps1"'
    [void](Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru)
}
function New-Text([string]$Text, [float]$Size = 10, [bool]$Bold = $false) {
    $label = [Windows.Forms.Label]::new(); $label.Text = $Text; $label.AutoSize = $true
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = [Drawing.Font]::new('Microsoft YaHei UI',$Size,$style)
    $label.Margin = [Windows.Forms.Padding]::new(0,0,0,8); $label.Dock = 'Top'
    return $label
}
function New-Stack {
    $table = [Windows.Forms.TableLayoutPanel]::new(); $table.ColumnCount = 1
    $table.AutoSize = $true; $table.AutoSizeMode = 'GrowAndShrink'; $table.Dock = 'Top'
    $table.Margin = [Windows.Forms.Padding]::new(0); return $table
}
function Add-StackRow($Table, $Control) {
    $row = $Table.RowCount; $Table.RowCount++
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $Table.Controls.Add($Control,0,$row)
}
function New-Check([string]$Text, [bool]$Checked) {
    $box = [Windows.Forms.CheckBox]::new(); $box.Text = $Text; $box.Checked = $Checked
    $box.AutoSize = $true; $box.Dock = 'Top'; $box.Margin = [Windows.Forms.Padding]::new(0,4,0,7)
    return $box
}
function New-Action([string]$Text) {
    $button = [Windows.Forms.Button]::new(); $button.Text = $Text
    $button.AutoSize = $true; $button.AutoSizeMode = 'GrowAndShrink'
    $button.MinimumSize = [Drawing.Size]::new(108,38)
    $button.Padding = [Windows.Forms.Padding]::new(10,4,10,4)
    $button.Margin = [Windows.Forms.Padding]::new(0,0,12,6)
    return $button
}
$form = [Windows.Forms.Form]::new(); $form.SuspendLayout()
$form.Text = '西电校园网自动登录'; $form.Font = [Drawing.Font]::new('Microsoft YaHei UI',10)
$form.AutoScaleMode = 'Dpi'; $form.AutoScaleDimensions = [Drawing.SizeF]::new(96,96)
$form.ClientSize = [Drawing.Size]::new(720,570); $form.MinimumSize = [Drawing.Size]::new(600,500)
$form.StartPosition = 'CenterScreen'; $form.AutoScroll = $true
$form.Icon = [Drawing.SystemIcons]::Information; $form.ShowInTaskbar = [bool]$settings.showTaskbarIcon
$root = New-Stack; $root.Padding = [Windows.Forms.Padding]::new(24,20,24,14); $form.Controls.Add($root)
$header = New-Stack
Add-StackRow $header (New-Text '校园网自动登录' 19 $true)
$intro = New-Text '换位置或认证失效后自动登录。代理可以保持开启。'
$intro.ForeColor = [Drawing.Color]::DimGray; Add-StackRow $header $intro
$header.Margin = [Windows.Forms.Padding]::new(0,0,0,16); Add-StackRow $root $header
$statusCard = New-Stack; $statusCard.Padding = [Windows.Forms.Padding]::new(16,13,16,7)
$statusCard.BackColor = [Drawing.Color]::FromArgb(241,246,251)
$statusCard.Margin = [Windows.Forms.Padding]::new(0,0,0,16)
$statusTitle = New-Text '正在检测校园网络' 11 $true
$statusLabel = New-Text '后台会自动检查并完成需要的校园网认证。'
$detailLabel = New-Text '等待获取连接状态' 9; $detailLabel.ForeColor = [Drawing.Color]::DimGray
Add-StackRow $statusCard $statusTitle; Add-StackRow $statusCard $statusLabel; Add-StackRow $statusCard $detailLabel
Add-StackRow $root $statusCard
$fields = [Windows.Forms.TableLayoutPanel]::new(); $fields.ColumnCount = 2
$fields.AutoSize = $true; $fields.AutoSizeMode = 'GrowAndShrink'; $fields.Dock = 'Top'
[void]$fields.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$fields.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
$fields.Margin = [Windows.Forms.Padding]::new(0,0,0,12)
$ssidBox = [Windows.Forms.TextBox]::new(); $ssidBox.Text = @($settings.ssids) -join ', '
$userBox = [Windows.Forms.TextBox]::new(); $userBox.Text = $settings.username
$passwordBox = [Windows.Forms.TextBox]::new(); $passwordBox.UseSystemPasswordChar = $true
$passwordBox.PlaceholderText = if ($settings.protectedPassword) { '已保存，留空保持原密码' } else { '输入校园网登录密码' }
$fieldBoxes = @($ssidBox,$userBox,$passwordBox); $fieldNames = @('校园 Wi-Fi','上网账号','上网密码')
for ($i = 0; $i -lt 3; $i++) {
    $fields.RowCount++
    [void]$fields.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $label = New-Text $fieldNames[$i]; $label.Dock = 'Fill'; $label.TextAlign = 'MiddleLeft'
    $label.Margin = [Windows.Forms.Padding]::new(0,0,20,12)
    $fieldBoxes[$i].Dock = 'Fill'; $fieldBoxes[$i].Margin = [Windows.Forms.Padding]::new(0,0,0,12)
    $fields.Controls.Add($label,0,$i); $fields.Controls.Add($fieldBoxes[$i],1,$i)
}
Add-StackRow $root $fields
$options = New-Stack
$enabledCheck = New-Check '启用校园网自动认证' ([bool]$settings.enabled)
$autoCheck = New-Check '登录 Windows 后在后台启动' (Test-Path -LiteralPath $startupPath)
$taskbarCheck = New-Check '设置窗口打开时，在任务栏显示图标' ([bool]$settings.showTaskbarIcon)
$trayCheck = New-Check '在右下角通知区域显示托盘图标' ([bool]$settings.showTrayIcon)
foreach ($check in @($enabledCheck,$autoCheck,$taskbarCheck,$trayCheck)) { Add-StackRow $options $check }
$options.Margin = [Windows.Forms.Padding]::new(0,0,0,14); Add-StackRow $root $options
$actions = [Windows.Forms.FlowLayoutPanel]::new(); $actions.AutoSize = $true
$actions.AutoSizeMode = 'GrowAndShrink'; $actions.Dock = 'Top'; $actions.WrapContents = $true
$actions.Margin = [Windows.Forms.Padding]::new(0,0,0,12)
$saveButton = New-Action '保存设置'; $retryButton = New-Action '立即检测'
$logButton = New-Action '查看日志'; $hideButton = New-Action '转为后台'
$quitButton = New-Action '退出程序'
foreach ($button in @($saveButton,$retryButton,$logButton,$hideButton,$quitButton)) { $actions.Controls.Add($button) }
Add-StackRow $root $actions
$footer = New-Text '密码仅通过 Windows 本机账户加密保存。隐藏图标后仍会自动认证，可从开始菜单重新打开。' 9
$footer.ForeColor = [Drawing.Color]::DimGray; Add-StackRow $root $footer
function Update-Wrapping {
    $width = [Math]::Max(240,$form.ClientSize.Width - $root.Padding.Horizontal - 28)
    foreach ($label in @($intro,$footer)) { $label.MaximumSize = [Drawing.Size]::new($width,0) }
    foreach ($label in @($statusTitle,$statusLabel,$detailLabel)) { $label.MaximumSize = [Drawing.Size]::new([Math]::Max(200,$width - $statusCard.Padding.Horizontal),0) }
}
$form.Add_Resize({ Update-Wrapping }); Update-Wrapping
$tray = [Windows.Forms.NotifyIcon]::new(); $tray.Icon = [Drawing.SystemIcons]::Information
$tray.Text = '西电校园网自动登录'; $tray.Visible = !$ValidateUi -and [bool]$settings.showTrayIcon
$menu = [Windows.Forms.ContextMenuStrip]::new()
$showItem = $menu.Items.Add('打开设置'); $pauseItem = $menu.Items.Add('暂停自动认证'); $exitItem = $menu.Items.Add('退出后台程序')
$tray.ContextMenuStrip = $menu
function Show-Settings { $form.Show(); $form.WindowState = 'Normal'; [void]$form.Activate() }
function Apply-Visibility { $form.ShowInTaskbar=$taskbarCheck.Checked; $tray.Visible=(!$ValidateUi -and $trayCheck.Checked) }
$showItem.Add_Click({ Show-Settings }); $tray.Add_DoubleClick({ Show-Settings })
$taskbarCheck.Add_CheckedChanged({ Apply-Visibility }); $trayCheck.Add_CheckedChanged({ Apply-Visibility })
$hideButton.Add_Click({ $form.Hide() })
$logButton.Add_Click({ if (Test-Path -LiteralPath $script:LogPath) { Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe" -ArgumentList ('"' + $script:LogPath + '"') } })
$saveButton.Add_Click({
    try {
        $fresh = Read-Settings
        $ssids = @($ssidBox.Text.Split(',',[StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object Trim | Where-Object { $_ })
        if (!$ssids.Count) { throw '请填写校园 Wi-Fi 名称。多个名称用英文逗号分隔。' }
        if ($passwordBox.Text.Length) {
            if (!$userBox.Text.Trim()) { throw '填写密码时也需要填写上网账号。' }
            $secure = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
            try { $protected = ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
        } else {
            if ($fresh.username -ne $userBox.Text.Trim()) { throw '更换账号时请重新填写密码。' }
            $protected = $fresh.protectedPassword
        }
        Write-JsonAtomic $script:ConfigPath @{ version=2; ssids=$ssids; username=$userBox.Text.Trim(); protectedPassword=$protected; enabled=$enabledCheck.Checked; showTaskbarIcon=$taskbarCheck.Checked; showTrayIcon=$trayCheck.Checked }
        Set-Autostart $autoCheck.Checked; Apply-Visibility
        $passwordBox.Clear(); if ($protected) { $passwordBox.PlaceholderText = '已保存，留空保持原密码' }
        [IO.File]::WriteAllText((Join-Path $script:DataRoot 'retry.request'),''); Start-Monitor
        $statusLabel.Text = '设置已保存。后台将在 15 秒内重新检查连接。'
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'请检查设置') }
})
$retryButton.Add_Click({ [IO.File]::WriteAllText((Join-Path $script:DataRoot 'retry.request'),''); Start-Monitor })
$pauseItem.Add_Click({ $fresh=Read-Settings; $fresh.enabled=!$fresh.enabled; Write-JsonAtomic $script:ConfigPath $fresh; $enabledCheck.Checked=$fresh.enabled; $pauseItem.Text=if($fresh.enabled){'暂停自动认证'}else{'恢复自动认证'} })
function Exit-Application { $script:MayExit=$true; [IO.File]::WriteAllText((Join-Path $script:DataRoot 'stop.request'),''); $form.Close() }
$exitItem.Add_Click({ Exit-Application }); $quitButton.Add_Click({ Exit-Application })
$form.Add_FormClosing({ param($sender,$eventArgs) if (!$script:MayExit) { $eventArgs.Cancel=$true; $form.Hide() } })
$timer = [Windows.Forms.Timer]::new(); $timer.Interval=1000
$timer.Add_Tick({
    try {
        $openPath=Join-Path $script:DataRoot 'open.request'
        if(Test-Path -LiteralPath $openPath){Remove-Item -LiteralPath $openPath; Show-Settings}
        $hidePath=Join-Path $script:DataRoot 'hide.request'
        if(Test-Path -LiteralPath $hidePath){Remove-Item -LiteralPath $hidePath; $form.Hide()}
        Write-JsonAtomic (Join-Path $script:DataRoot 'ui-state.json') @{pid=$PID;visible=$form.Visible;showTaskbarIcon=$form.ShowInTaskbar;showTrayIcon=$tray.Visible;updated=[DateTimeOffset]::Now.ToString('o')}
        $status=$null
        if(Test-Path -LiteralPath $script:StatusPath){$status=Get-Content -LiteralPath $script:StatusPath -Raw | ConvertFrom-Json}
        $age=if($status){([DateTimeOffset]::Now-[DateTimeOffset]::Parse($status.updated)).TotalSeconds}else{999}
        if($age -gt 60 -and ([DateTimeOffset]::Now-$script:LastWatchdog).TotalSeconds -gt 30){
            $probeMutex=[Threading.Mutex]::new($false,'Local\XidianCampusLoginWorker'); $free=$false
            try { try{$free=$probeMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$free=$true}; if($free){$probeMutex.ReleaseMutex();Start-Monitor} } finally {$probeMutex.Dispose()}
            $script:LastWatchdog=[DateTimeOffset]::Now
        }
        if(!$status){return}
        $statusTitle.Text=if($age -gt 60){'正在恢复后台检测'}elseif($status.state -eq 'ONLINE'){'校园网已联网'}elseif($status.state -eq 'PAUSED'){'自动认证已暂停'}else{'校园网连接检测'}
        $statusLabel.Text=if($age -gt 60){'连接状态尚未更新，程序会自动尝试恢复。'}else{$status.message}
        $detailLabel.Text=if($status.ip){$status.ssid+'   ·   '+$status.ip}else{'等待连接配置的校园 Wi-Fi'}
        $statusTitle.ForeColor=if($status.state -eq 'ONLINE' -and $age -lt 60){[Drawing.Color]::FromArgb(23,105,68)}else{[Drawing.Color]::FromArgb(134,89,26)}
        $popupKey=$status.state+'|'+$status.message
        if($tray.Visible -and $age -lt 60 -and $status.state -in @('ACCOUNT_ERROR','LOGIN_FAILED','NEED_SETTINGS') -and $script:LastPopup -ne $popupKey){$tray.ShowBalloonTip(5000,'校园网自动登录',$status.message,[Windows.Forms.ToolTipIcon]::Info);$script:LastPopup=$popupKey}
    }catch{}
})
$form.ResumeLayout($true)
$form.Add_Shown({
    $available = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    if ($form.Height -gt $available.Height - 30) { $form.Height = [Math]::Max($form.MinimumSize.Height,$available.Height - 30) }
})
try {
    if($ValidateUi){
        if($UiScale -ne 1){$form.Scale([Drawing.SizeF]::new($UiScale,$UiScale));Update-Wrapping}
        $form.Show(); [Windows.Forms.Application]::DoEvents(); $form.PerformLayout()
        if($RenderUi){$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($RenderUi,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}}
        $buttonsFit=($actions.Controls | ForEach-Object {$_.PreferredSize.Width -le $_.Width -and $_.PreferredSize.Height -le $_.Height}) -notcontains $false
        [pscustomobject]@{passwordMasked=$passwordBox.UseSystemPasswordChar;layout='TableLayoutPanel';dpi=$form.DeviceDpi;scale=$UiScale;taskbarOptionPresent=([bool]$taskbarCheck);trayOptionPresent=([bool]$trayCheck);buttonsFit=$buttonsFit;footerVisible=($footer.Bounds.Bottom -le $root.Height);formWidth=$form.Width;formHeight=$form.Height} | ConvertTo-Json
        $form.Hide()
    }else{
        Start-Monitor; $timer.Start()
        if($Background){$form.Add_Shown({$form.Hide()})}
        [Windows.Forms.Application]::Run($form)
    }
}finally{$timer.Stop();$timer.Dispose();$tray.Visible=$false;$tray.Dispose();$form.Dispose();if($script:OwnMutex){$appMutex.ReleaseMutex()};$appMutex.Dispose()}
