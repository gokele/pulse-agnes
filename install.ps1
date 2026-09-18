<#
  pulse-agent Windows 一键安装 / 卸载脚本

    以管理员身份打开 PowerShell，执行：
    irm https://raw.githubusercontent.com/gokele/pulse-agnes/main/install.ps1 | iex; `
      Install-PulseAgent -Server <面板地址> -Id <节点ID> -Token <该节点的密钥>

    卸载：
    irm https://raw.githubusercontent.com/gokele/pulse-agnes/main/install.ps1 | iex; `
      Install-PulseAgent -Uninstall

  重复执行即为升级：换掉可执行文件并重启服务，节点 ID、密钥、分盘与网卡设置照旧。

  可执行文件与校验和都从 Agent 的发布仓库取，面板只负责接收上报，不分发任何文件。
  Agent 与服务端各自发版，所以这里是 pulse-agnes 而不是 pulse-releases。

  配置写在服务自己的注册表键下（Environment，REG_MULTI_SZ），不写进命令行：
  Windows 上任何用户都能看到别人进程的命令行（Win32_Process.CommandLine），
  密钥放在那里等于公开；服务键只有管理员读得到。Agent 本来就认这些环境变量，
  与 Linux 那边的 agent.env 是同一套。
#>

function Install-PulseAgent {
  [CmdletBinding()]
  # 这是个交互式安装脚本，输出就是给人看的，不该进管道
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
  param(
    [string]$Server,
    [string]$Token,
    [string]$Id,
    [string]$Name,
    # 要统计的挂载点，逗号分隔，如 "C:\,D:\"；默认只看系统盘
    [string]$Disk,
    # 只统计这些网卡，逗号分隔，如 "以太网"；默认自动判断
    [string]$Iface,
    [string]$Release = 'latest',
    [string]$Repo = 'gokele/pulse-agnes',
    # 直接指定可执行文件地址（跳过 GitHub 查询与校验和比对）
    [string]$BinaryUrl,
    # 跳过 TLS 证书校验（面板用自签证书时）
    [switch]$Insecure,
    [switch]$Uninstall
  )

  $ErrorActionPreference = 'Stop'

  # 注册服务、写 Program Files 都要管理员。这个检查放在最前面：
  # 后面每一步都需要它，先失败在这里，报错才说得清是权限问题。
  $isAdmin = $false
  try {
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }
  catch {
    throw '这个脚本只能在 Windows 上运行'
  }
  if (-not $isAdmin) { throw '请以管理员身份运行 PowerShell' }

  # Windows PowerShell 5.1 默认还在用 SSL 3.0 / TLS 1.0，而 GitHub 只收 TLS 1.2 以上，
  # 不显式抬上去的话下载会直接失败，报的还是「基础连接已关闭」这种看不懂的错。
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }
  catch {
    # PowerShell 7 用的是 .NET 的默认协议，动不了这个开关，也不需要动
    Write-Verbose "设置 TLS 1.2 失败（$($_.Exception.Message)），按运行时默认继续"
  }

  $serviceName = 'pulse-agent'
  $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
  $programFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
  $installDir = Join-Path $programFiles 'pulse-agent'
  $exePath = Join-Path $installDir 'pulse-agent.exe'

  if ($Uninstall) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
      Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
      # sc.exe delete 而不是 Remove-Service：后者要 PowerShell 6+
      & sc.exe delete $serviceName | Out-Null
      Start-Sleep -Seconds 1
    }
    if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue }
    Write-Host 'pulse-agent 已卸载'
    return
  }

  if (-not $Id) { $Id = $env:COMPUTERNAME }
  if (-not $Token) { throw '缺少 -Token，请从后台的「安装命令」复制完整命令' }
  if (-not $Server) { throw '缺少 -Server，请填面板地址，如 -Server https://pulse.example.com' }
  $Server = $Server.TrimEnd('/')
  if (-not $Name) { $Name = $Id }

  # 重复执行是升级：没显式传的项沿用上次写下的值，
  # 不然升一次级就把分盘、网卡的配置抹掉了
  $previous = Get-PulseAgentEnv -ServiceKey $serviceKey
  if (-not $Disk) { $Disk = $previous['PULSE_DISK'] }
  if (-not $Iface) { $Iface = $previous['PULSE_IFACE'] }

  switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $arch = 'amd64' }
    'ARM64' { $arch = 'arm64' }
    default { throw "不支持的架构: $env:PROCESSOR_ARCHITECTURE" }
  }
  $asset = "pulse-agent-windows-$arch.exe"

  New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  $tmp = Join-Path $env:TEMP "pulse-agent-$([guid]::NewGuid()).exe"

  # --- 下载 ---------------------------------------------------------------
  # 不带 -BinaryUrl 时走 GitHub Release，并强制校验 SHA-256。
  try {
    if ($BinaryUrl) {
      Write-Host "下载 $BinaryUrl（已指定直链，跳过校验和比对）"
      Invoke-WebRequest -Uri $BinaryUrl -OutFile $tmp -UseBasicParsing
    }
    else {
      $base = if ($Release -eq 'latest') {
        "https://github.com/$Repo/releases/latest/download"
      }
      else {
        "https://github.com/$Repo/releases/download/$Release"
      }
      Write-Host "下载 $base/$asset"
      Invoke-WebRequest -Uri "$base/$asset" -OutFile $tmp -UseBasicParsing

      $sumsPath = "$tmp.checksums"
      try {
        Invoke-WebRequest -Uri "$base/checksums.txt" -OutFile $sumsPath -UseBasicParsing
      }
      catch {
        throw '下载 checksums.txt 失败，无法校验可执行文件，已放弃安装'
      }
      $want = $null
      foreach ($line in Get-Content $sumsPath) {
        $parts = $line.Trim() -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].TrimStart('*').Trim() -eq $asset) {
          $want = $parts[0].Trim()
          break
        }
      }
      Remove-Item -Force $sumsPath -ErrorAction SilentlyContinue
      if (-not $want) { throw "checksums.txt 里没有 $asset 的校验和，已放弃安装" }

      $got = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
      if ($got -ne $want.ToUpper()) {
        throw "校验和不匹配，已丢弃下载内容`n  期望 $want`n  实际 $got"
      }
      Write-Host "校验和通过 ($($got.Substring(0, 16))…)"
    }

    if ((Get-Item $tmp).Length -eq 0) { throw '下载到的文件是空的' }
  }
  catch {
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    throw
  }

  # --- 安装 ---------------------------------------------------------------
  $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if ($service) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    # 正在运行的 exe 停掉之后才能覆盖；服务停止有几百毫秒的滞后
    Start-Sleep -Milliseconds 800
  }
  Move-Item -Force -Path $tmp -Destination $exePath

  if (-not $service) {
    # 以 LocalSystem 运行（New-Service 的默认账户）：ICMP 探测要创建 raw socket，
    # 普通账户没这个权限。命令行里只有 exe 路径，配置走下面的环境变量。
    New-Service -Name $serviceName -BinaryPathName "`"$exePath`"" `
      -DisplayName 'Pulse Agent' -StartupType Automatic `
      -Description 'Pulse 探针：采集本机状态并上报到面板' | Out-Null
  }

  $env_values = @(
    "PULSE_SERVER=$Server"
    "PULSE_TOKEN=$Token"
    "PULSE_NODE_ID=$Id"
    "PULSE_NODE_NAME=$Name"
  )
  if ($Disk) { $env_values += "PULSE_DISK=$Disk" }
  if ($Iface) { $env_values += "PULSE_IFACE=$Iface" }
  if ($Insecure) { $env_values += 'PULSE_INSECURE=1' }
  New-ItemProperty -Path $serviceKey -Name 'Environment' -PropertyType MultiString `
    -Value $env_values -Force | Out-Null

  # 日志写进事件查看器的「应用程序」，先把来源注册上，否则写不进去。
  # 用 .NET 而不是 New-EventLog：那个 cmdlet 只有 Windows PowerShell 5.1 才有，
  # 在 PowerShell 7 上会直接报「找不到命令」，整条安装就断在这儿。
  try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($serviceName)) {
      [System.Diagnostics.EventLog]::CreateEventSource($serviceName, 'Application')
    }
  }
  catch {
    Write-Host "注册事件日志来源失败（$($_.Exception.Message)），日志可能看不到，但不影响采集"
  }

  # 崩溃与自动更新之后都靠它把服务拉回来。Windows 默认什么都不做，
  # Agent 更新完自己退出之后就再也起不来了 —— 和 Linux 那边不写 Restart=always
  # 是同一个坑，必须显式配。
  & sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
  # 正常退出（自动更新那次）也要重启，默认只在崩溃时才触发
  & sc.exe failureflag $serviceName 1 | Out-Null

  Start-Service -Name $serviceName
  Start-Sleep -Seconds 2
  $state = (Get-Service -Name $serviceName).Status
  if ($state -ne 'Running') {
    throw "pulse-agent 启动失败（当前状态 $state），看看事件查看器里「应用程序」下 pulse-agent 的记录"
  }
  Write-Host "pulse-agent 已启动：节点 $Id（$Name） → $Server"
  Write-Host "查看日志：Get-EventLog -LogName Application -Source pulse-agent -Newest 20"
}

# Get-PulseAgentEnv 读回服务键里已有的配置，升级时用来沿用上次的值。
function Get-PulseAgentEnv {
  param([string]$ServiceKey)
  $out = @{}
  $prop = Get-ItemProperty -Path $ServiceKey -Name 'Environment' -ErrorAction SilentlyContinue
  if (-not $prop) { return $out }
  foreach ($line in $prop.Environment) {
    $i = $line.IndexOf('=')
    if ($i -gt 0) { $out[$line.Substring(0, $i)] = $line.Substring($i + 1) }
  }
  return $out
}
