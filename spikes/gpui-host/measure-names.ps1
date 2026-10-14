param([string[]]$Names = @('weaver-widget', 'weaver-renderer', 'weaverd'), [int]$Window = 15)
# Same counters as measure.ps1, sampled over already-running processes.
$procs = Get-Process -Name $Names -ErrorAction SilentlyContinue
$t0 = @{}; foreach ($pr in $procs) { $t0[$pr.Id] = $pr.TotalProcessorTime.TotalMilliseconds }
$sw = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds $Window
$elapsed = $sw.Elapsed.TotalMilliseconds
$rows = foreach ($pr in $procs) {
  $pr.Refresh()
  $perf = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess=$($pr.Id)"
  [pscustomobject]@{
    name       = $pr.ProcessName
    pid        = $pr.Id
    cpu_pct    = [math]::Round(100 * ($pr.TotalProcessorTime.TotalMilliseconds - $t0[$pr.Id]) / $elapsed, 2)
    priv_ws_mb = [math]::Round($perf.WorkingSetPrivate / 1MB, 2)
    priv_mb    = [math]::Round($pr.PrivateMemorySize64 / 1MB, 2)
    threads    = $pr.Threads.Count
  }
}
$rows | Sort-Object name | Format-Table -AutoSize | Out-String | Write-Output
$noDaemon = $rows | Where-Object name -ne 'weaverd'
"TOTAL(excl weaverd) cpu=$([math]::Round(($noDaemon | Measure-Object cpu_pct -Sum).Sum,2))% priv_ws=$([math]::Round(($noDaemon | Measure-Object priv_ws_mb -Sum).Sum,2))MiB priv=$([math]::Round(($noDaemon | Measure-Object priv_mb -Sum).Sum,2))MiB threads=$(($noDaemon | Measure-Object threads -Sum).Sum)"
