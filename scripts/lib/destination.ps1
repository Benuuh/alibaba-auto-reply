# Pure destination facts; grammar identifies intent, not warehouse existence/serviceability.
# Candidate grammar: 3-4 ASCII letters + 1-2 digits, with Amazon/FBA receiving context.
function Get-QuoteDestination {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Conversation)
    $trusted = [bool]$Conversation.Order.Confident
    $amazon = $false; $targets = @{}; $evidence = @(); $notes = @(); $postal = ''; $untrustedChange = $false; $unsupported = $false
    foreach ($m in @($Conversation.Messages)) {
        if (-not $m -or $m.IsSystemCard) { continue }
        $t = Get-MsgPlainText ([string]$m.Orig)
        $t = $t -replace 'https?://\S+|\b\S+\.(?:pdf|xlsx?|csv|jpg|png|zip)\b', ''
        # A question supplies context only; the code still must come from a buyer.
        $humanConfirmed = $m.Source -eq 'human' -and $t -match '(?i)confirmed buyer destination|buyer confirmed|confirmed delivery destination|客户确认|已确认.*(?:目的|收货|送到)'
        if ($m.Role -ne 'buyer' -and -not $humanConfirmed) {
            if ($t -match '(?i)(which|what|provide|send|share).*(amazon|fba).*(warehouse|code)|哪个.*亚马逊.*仓') { $amazon = $true }
            continue
        }
        $explicit = $t -match '(?i)\b(amazon|fba)\b|亚马逊'
        $replace = $t -match '(?i)\b(change|switch|instead|replace|now deliver|now ship)\b|改送|改为|换仓|改到|不是.+改'
        $cancel = $t -match "(?i)(cancel|no longer|do not|don'?t|not).{0,18}(ship|deliver|send).{0,18}(amazon|fba)|取消.*(亚马逊|送仓)|不再.*(亚马逊|送仓)|不送.*亚马逊"
        if ($cancel) {
            $targets = @{}; $postal = ''; $amazon = $false; $untrustedChange = $untrustedChange -or (-not $trusted)
            $notes += 'amazon delivery cancelled'; $evidence += @{ Source = 'buyer'; Text = $m.Orig; MessageId = $m.StableId }
            continue
        }
        $excluded = $t -match '(?i)\b(model|sku|order\s*(number|no\.?))\b|型号|订单号|\b(pick\s*up|pickup|collect).{0,20}\bfrom\b|提货|取货|\b(used|previous|formerly|before|historical)\b|以前|历史|曾经'
        if ($explicit -and -not $excluded) { $amazon = $true }
        $codes = @()
        if (($explicit -or ($amazon -and $trusted)) -and -not $excluded) {
            if ($replace -and $trusted) { $unsupported = $false }
            foreach ($candidate in [regex]::Matches($t, '(?i)(?<![A-Z0-9])[A-Z]{1,8}\d{1,8}(?![A-Z0-9])')) {
                if ($candidate.Value -notmatch '^(?i)[A-Z]{3,4}\d{1,2}$') { $unsupported = $true; $notes += ('unsupported candidate ' + $candidate.Value) }
            }
            foreach ($hit in [regex]::Matches($t, '(?i)(?<![A-Z0-9])[A-Z]{3,4}\d{1,2}(?![A-Z0-9])')) {
                $code = $hit.Value.ToUpperInvariant(); $prefix = $t.Substring(0, $hit.Index)
                if ($prefix -match '(?i)(?:\bnot|\bno|不是|不要|不送|非)\s*(?:amazon\s*|fba\s*)?$') {
                    $targets.Remove('amazon:' + $code); $untrustedChange = $untrustedChange -or (-not $trusted)
                    $notes += ('negated ' + $code); continue
                }
                if ($codes -notcontains $code) { $codes += $code }
            }
        }
        $address = ''
        if (-not $excluded -and $t -notmatch '(?i)\b(send|share|provide|need|unknown|no address|what|which)\b.{0,25}\baddress\b|没有地址|地址未知') {
            $pa = [regex]::Match($t, '(?i)\b\d{1,5}\s+(?:[A-Za-z]+\s+){1,3}(?:rd|st|ave|blvd|ln|dr|pkwy|hwy|street|road|avenue|lane|drive|boulevard|way)\b|(?:delivery address|shipping address|address|收货地址|私人地址|地址|endere[cç]o|direcci[oó]n)\s*[:：]\s*\S.+')
            if ($pa.Success) {
                $address = $t.Substring($pa.Index) -replace '^(?i)(delivery address|shipping address|address|收货地址|私人地址|地址|endere[cç]o|direcci[oó]n)\s*[:：]\s*', ''
                $address = ($address -split '(?i)\b(?:Shipping|Total Boxes|Total Weight|Box Dimensions|Box Weight|Cartons|Delivery Method)\s*[:：]|(?:运输|件数|数量)\s*[:：]', 2)[0]
                $address = (($address -replace '\?{2,}|<br\s*/?>', ' ') -replace '\s+', ' ').Trim()
            }
        }
        if ($replace -and ($codes.Count -gt 0 -or $address)) {
            if ($trusted) { $targets = @{}; $postal = '' } else { $untrustedChange = $true }
        }
        $ev = @{ Source = $(if ($humanConfirmed) { 'human' } else { 'buyer' }); Text = $m.Orig; MessageId = $m.StableId }
        foreach ($code in $codes) { $targets['amazon:' + $code] = @{ Kind = 'amazon_warehouse'; Code = $code; Display = 'Amazon ' + $code; Evidence = $ev } }
        if ($address) {
            $postal = $address
            # A warehouse and its address in the same message are associated unless explicitly separate.
            if ($codes.Count -eq 0 -or $t -match '(?i)\b(?:also|or)\b|another|separate|另外|另一个|或者') {
                $targets['postal:' + $address.ToLowerInvariant()] = @{ Kind = 'postal_address'; Code = ''; Display = $address; Evidence = $ev }
                if ($replace -and $trusted) { $amazon = $false }
            }
        }
        if ($codes.Count -gt 0 -or $address) { $evidence += $ev }
    }
    $kind = 'unknown'; $codeValue = ''; $display = ''; $usable = $false; $reason = 'no supported buyer destination'; $source = 'unknown'
    if ($targets.Count -gt 1 -or $untrustedChange -or ($unsupported -and $targets.Count -gt 0)) { $kind = 'ambiguous'; $reason = 'conflicting targets, unsupported alternative or change without trusted order' }
    elseif ($unsupported) { $reason = 'unsupported warehouse candidate grammar' }
    elseif ($targets.Count -eq 1) {
        $chosen = @($targets.Values)[0]; $kind = $chosen.Kind; $codeValue = $chosen.Code; $display = $chosen.Display
        $usable = $true; $source = $chosen.Evidence.Source; $reason = $source + ' provided destination'
    }
    return [pscustomobject]@{
        Kind = $kind; WarehouseCode = $codeValue; DisplayName = $display; QuoteUsable = $usable
        HasPostalAddress = [bool]$postal; PostalAddress = $postal; Source = $source; Evidence = @($evidence)
        Candidates = @($targets.Values | ForEach-Object { $_.Display }); Reason = $reason; Notes = @($notes); AmazonContext = $amazon
    }
}
