# lib\task_facts.ps1 - 已验证任务确认资料 -> 统一事实模型的**最小共享适配层**（第三轮 spec §5.4）
#
# 为什么需要：新增的确认记录不能只供措辞授权，否则会出现"已确认尺寸但系统仍认为缺尺寸"的第二套状态。
#   本文件把人工任务存储里**可信的结构化确认**（supplier_reply 记录的 ConfirmedFields）导出为带来源的
#   证据条目，交给纯计算的事实引擎合并；事实引擎自己绝不读任务文件。
#
# 关联规则（spec §5.4 第 1 条）：
#   * 仅合并**同买家**、**同供应商**及**同一运输资料采集流程**的可信记录；
#   * 关联必须使用持久当前 FlowRef 和确切供应商身份；单一任务/旧触发不作为独立关联；
#   * 无法确认关联时不跨批次、不跨供应商套用；多个候选有冲突交由统一 conflict/needs_confirmation；
#   * 纯文本调用必须显式要求（-WithTaskEvidence），默认不访问任务存储。
#
# 依赖：lib\human_tasks.ps1（任务存储与结构化记录）。缺失时防御式加载。
if (-not (Get-Command Get-HumanTaskList -ErrorAction SilentlyContinue)) {
    $hf = Join-Path $PSScriptRoot 'human_tasks.ps1'
    if (Test-Path $hf) { . $hf }
}

function Get-TaskFactEvidenceText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return (([string]$Text) -replace '\s+', ' ').Trim().ToLowerInvariant()
}

# 该任务与当前会话/流程是否可确认关联。
function Get-TaskConfirmedEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [string]$TaskId = '',
        [string]$SupplierIdentity = '',
        $Conversation = $null
    )
    $out = New-Object System.Collections.ArrayList
    if (-not (Get-Command Get-HumanTaskList -ErrorAction SilentlyContinue)) { return @() }
    $tasks = @()
    if ($TaskId) { $tasks = @(Get-HumanTaskList -Buyer $Buyer -TaskId $TaskId) }
    else { $tasks = @(Get-HumanTaskList -Buyer $Buyer) }
    foreach ($t in $tasks) {
        if (-not $t) { continue }
        if ((Resolve-HumanTaskKind ([string]$t.kind)) -ne 'supplier_verification') { continue }
        $supKey = ''
        if ($t.PSObject.Properties.Name -contains 'supplierKey') { $supKey = Get-TaskSupplierIdentity $t }
        if ($SupplierIdentity -and $supKey -ne [string]$SupplierIdentity) { continue }
        $assoc = Test-TaskFlowAssociation $t $Conversation -ExactSelection:([bool]$TaskId)
        if (-not $assoc) { continue }
        foreach ($cf in @(Get-HumanTaskConfirmedFields $t)) {
            if (-not $cf) { continue }
            $refs = New-Object System.Collections.ArrayList
            [void]$refs.Add('task:' + [string]$cf.TaskId)
            [void]$refs.Add('record:' + [string]$cf.RecordId)
            if ($cf.SourceRef) { [void]$refs.Add('source:' + [string]$cf.SourceRef) }
            [void]$out.Add([pscustomobject]@{
                FlowId = $cf.FlowId
                FactRef = $cf.FactRef
                FieldKey         = [string]$cf.FieldKey
                Value            = [string]$cf.Value
                Unit             = [string]$cf.Unit
                Scope            = [string]$cf.Scope
                Status           = 'provided'
                Source           = 'supplier-reply-record'
                SourceRefs       = @($refs.ToArray())
                TaskId           = [string]$cf.TaskId
                RecordId         = [string]$cf.RecordId
                SupplierIdentity = $(if ([string]$cf.SupplierIdentity) { [string]$cf.SupplierIdentity } else { $supKey })
                BatchRef         = [string]$cf.BatchRef
                ObservedAtUtc    = [string]$cf.RecordedAtUtc
                BuyerKey         = [string]$t.buyerKey
            })
        }
    }
    return @($out.ToArray())
}
