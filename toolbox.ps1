<#
  Mithril Toolbox - utilitario Windows (instalar programas, tweaks, drivers)
  Uso local:   .\toolbox.ps1
  Uso remoto:  & ([ScriptBlock]::Create((irm https://SEU-HOST/toolbox.ps1))) -BaseUrl https://SEU-HOST
  Os arquivos apps.json e tweaks.json ficam na mesma pasta (ou em -BaseUrl).
#>
param([string]$BaseUrl = "")

# ---------- Requer administrador ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Execute como Administrador." -ForegroundColor Red
    return
}

Add-Type -AssemblyName PresentationFramework
$ErrorActionPreference = "Continue"
$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:LogFile = Join-Path $env:TEMP "mithril-toolbox.log"

function Get-Config([string]$file) {
    if ($BaseUrl) { return Invoke-RestMethod "$($BaseUrl.TrimEnd('/'))/$file" }
    return Get-Content (Join-Path $script:Root $file) -Raw -Encoding UTF8 | ConvertFrom-Json
}

$Apps   = @(Get-Config "apps.json")
$Tweaks = @(Get-Config "tweaks.json")

# ---------- Interface ----------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Mithril Toolbox" Width="900" Height="650" WindowStartupLocation="CenterScreen">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="150"/>
    </Grid.RowDefinitions>
    <TabControl Grid.Row="0">
      <TabItem Header="Instalar">
        <DockPanel Margin="8">
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
            <Button Name="BtnInstall" Content="Instalar selecionados" Padding="14,6"/>
          </StackPanel>
          <ScrollViewer><StackPanel Name="AppsPanel"/></ScrollViewer>
        </DockPanel>
      </TabItem>
      <TabItem Header="Performance">
        <DockPanel Margin="8">
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
            <Button Name="BtnApply" Content="Aplicar selecionados" Padding="14,6" Margin="0,0,8,0"/>
            <Button Name="BtnUndo" Content="Desfazer selecionados" Padding="14,6"/>
          </StackPanel>
          <ScrollViewer><StackPanel Name="TweaksPanel"/></ScrollViewer>
        </DockPanel>
      </TabItem>
      <TabItem Header="Drivers">
        <StackPanel Margin="8">
          <TextBlock TextWrapping="Wrap" Margin="0,0,0,8"
            Text="Verifica dispositivos com problema e procura drivers pendentes no Windows Update. Requer internet."/>
          <StackPanel Orientation="Horizontal">
            <Button Name="BtnScanDrv" Content="Analisar" Padding="14,6" Margin="0,0,8,0"/>
            <Button Name="BtnInstDrv" Content="Instalar drivers encontrados" Padding="14,6"/>
          </StackPanel>
        </StackPanel>
      </TabItem>
    </TabControl>
    <TextBox Name="LogBox" Grid.Row="1" Margin="0,8,0,0" IsReadOnly="True"
             VerticalScrollBarVisibility="Auto" FontFamily="Consolas"/>
  </Grid>
</Window>
"@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in "AppsPanel","TweaksPanel","BtnInstall","BtnApply","BtnUndo","BtnScanDrv","BtnInstDrv","LogBox") {
    $ui[$n] = $win.FindName($n)
}

function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    $ui.LogBox.AppendText($line + "`r`n"); $ui.LogBox.ScrollToEnd()
    Add-Content -Path $script:LogFile -Value $line
    $win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

# ---------- Listas ----------
$appBoxes = @{}
foreach ($grp in ($Apps | Group-Object category)) {
    $h = New-Object Windows.Controls.TextBlock
    $h.Text = $grp.Name; $h.FontWeight = "Bold"; $h.Margin = "0,8,0,2"
    [void]$ui.AppsPanel.Children.Add($h)
    foreach ($a in $grp.Group) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = if ($a.note) { "$($a.name)  -  $($a.note)" } else { $a.name }
        $cb.Margin = "12,2,0,2"
        $appBoxes[$a.id] = $cb
        [void]$ui.AppsPanel.Children.Add($cb)
    }
}
$tweakBoxes = @{}
foreach ($t in $Tweaks) {
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Content = "$($t.name)  -  $($t.note)"; $cb.Margin = "0,3,0,3"
    $tweakBoxes[$t.id] = $cb
    [void]$ui.TweaksPanel.Children.Add($cb)
}

# ---------- Instalacao ----------
function Install-App($a) {
    Log "Instalando: $($a.name)"
    if ($a.wingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        winget install --id $a.wingetId -e --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { if ($_ -match '\S') { Log "  $_" } }
        if ($LASTEXITCODE -eq 0) { Log "  OK"; return }
        Log "  winget falhou (codigo $LASTEXITCODE)."
    }
    if ($a.url) {
        $dest = Join-Path $env:TEMP $a.fileName
        Log "  Baixando $($a.url)"
        Invoke-WebRequest -Uri $a.url -OutFile $dest -UseBasicParsing
        if ($a.sha256) {
            $h = (Get-FileHash $dest -Algorithm SHA256).Hash
            if ($h -ne $a.sha256.ToUpper()) { Log "  HASH INVALIDO - abortado"; return }
        }
        Start-Process $dest
        Log "  Instalador iniciado."
        return
    }
    if ($a.openUrl) { Start-Process $a.openUrl; Log "  Pagina de download aberta." }
}

$ui.BtnInstall.Add_Click({
    $sel = $Apps | Where-Object { $appBoxes[$_.id].IsChecked }
    if (-not $sel) { Log "Nada selecionado."; return }
    foreach ($a in $sel) { try { Install-App $a } catch { Log "  Erro: $_" } }
    Log "Concluido."
})

# ---------- Tweaks ----------
function Set-Tweak($t, [bool]$apply) {
    $mode = if ($apply) { "apply" } else { "undo" }
    switch ($t.type) {
        "registry" {
            foreach ($i in $t.items) {
                if (-not (Test-Path $i.path)) { New-Item -Path $i.path -Force | Out-Null }
                $val = if ($apply) { $i.apply } else { $i.undo }
                New-ItemProperty -Path $i.path -Name $i.name -Value $val -PropertyType $i.type -Force | Out-Null
            }
        }
        "service" {
            $s = if ($apply) { $t.applyStartup } else { $t.undoStartup }
            Set-Service -Name $t.service -StartupType $s
            if ($s -eq "Disabled") { Stop-Service -Name $t.service -Force -ErrorAction SilentlyContinue }
        }
        "powercfg" {
            powercfg /setactive $(if ($apply) { $t.apply } else { $t.undo }) | Out-Null
        }
        "command" {
            $c = if ($apply) { $t.apply } else { $t.undo }
            if ($c) { Invoke-Expression $c } else { Log "  (sem desfazer)" }
        }
    }
}

function Run-Tweaks([bool]$apply) {
    $sel = $Tweaks | Where-Object { $tweakBoxes[$_.id].IsChecked }
    if (-not $sel) { Log "Nada selecionado."; return }
    if ($apply) {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "Mithril Toolbox" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Log "Ponto de restauracao criado."
        } catch { Log "Aviso: ponto de restauracao nao criado ($($_.Exception.Message))" }
    }
    foreach ($t in $sel) {
        try { Set-Tweak $t $apply; Log "$(if ($apply) {'Aplicado'} else {'Desfeito'}): $($t.name)" }
        catch { Log "Erro em $($t.name): $_" }
    }
    Log "Concluido. Alguns ajustes exigem reiniciar."
}
$ui.BtnApply.Add_Click({ Run-Tweaks $true })
$ui.BtnUndo.Add_Click({ Run-Tweaks $false })

# ---------- Drivers ----------
$script:PendingDrivers = $null
$ui.BtnScanDrv.Add_Click({
    Log "Dispositivos com problema:"
    $bad = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in "Error","Unknown" }
    if ($bad) { $bad | ForEach-Object { Log "  $($_.FriendlyName) [$($_.Status)]" } } else { Log "  Nenhum." }
    Log "Procurando drivers no Windows Update (pode demorar)..."
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search("IsInstalled=0 and Type='Driver'")
        $script:PendingDrivers = $res.Updates
        if ($res.Updates.Count -eq 0) { Log "  Nenhum driver pendente." }
        else { foreach ($u in $res.Updates) { Log "  Disponivel: $($u.Title)" } }
    } catch { Log "Erro na busca: $_" }
})

$ui.BtnInstDrv.Add_Click({
    if (-not $script:PendingDrivers -or $script:PendingDrivers.Count -eq 0) { Log "Rode 'Analisar' primeiro."; return }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $script:PendingDrivers) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }
        Log "Baixando $($coll.Count) driver(s)..."
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        Log "Instalando..."
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $r = $inst.Install()
        Log "Resultado: codigo $($r.ResultCode). Reinicio necessario: $($r.RebootRequired)"
    } catch { Log "Erro: $_" }
})

Log "Pronto. Log completo em $script:LogFile"
[void]$win.ShowDialog()
