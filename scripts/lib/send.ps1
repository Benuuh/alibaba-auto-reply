# lib/send.ps1 - OneTalk 消息发送统一实现:打开会话 + 身份校验 + 原生 setter 填值 + 发送按钮 + 输入框清空校验。
# 返回格式(monitor/nudge 兼容): "OPEN_FAIL (..)" / "ABORT_WRONG_CONVO (expected=.., current=..)" / "NO_TEXTAREA" / "FILLED | CLICKED | SENT_OK" / ".. | NOT_SENT"
# 依赖: config.ps1, lib\cdp.ps1(Invoke-CdpEval), reply_engine.ps1(Get-StateKey)
function Send-OneTalkMessage([string]$buyer, [string]$text) {
    # 1) 打开会话(按买家名匹配列表项)
    $esc = $buyer.Replace("\","\\").Replace("'","\'").Replace('"','\"')
    $js1 = @"
(function(){
  var el = Array.from(document.querySelectorAll('.contact-item-container')).find(function(e){
    var nameEl = e.querySelector('.contact-info .name');
    var nameTxt = (nameEl && nameEl.innerText) || '';
    var full = (e.innerText || '') + '|' + nameTxt;
    return full.indexOf('$esc') >= 0;
  });
  if (!el) return 'NOT_FOUND';
  el.click();
  return 'CLICKED';
})()
"@
    $r1 = Invoke-CdpEval $js1
    if ($r1 -notmatch 'CLICKED') { return "OPEN_FAIL ($r1)" }
    Start-Sleep -Seconds 3

    # 2) 身份校验:当前会话名必须与目标一致(防串台/防错发;排除客户详情卡片)
    $jsName = @"
(function(){
  var cands = [];
  var hdr = document.querySelector('.content-header');
  if (hdr) {
    var t = (hdr.innerText || '').trim().split('\n')[0].trim();
    if (t && t.length < 60 && /[A-Za-z]/.test(t)) cands.push(t);
  }
  Array.from(document.querySelectorAll('[class*=header] [class*=name], [class*=Title], h1,h2,h3,[class*=contact-name]')).forEach(function(e){
    if (e.closest && e.closest('.alicrm-customer-detail-card')) return;
    var t = (e.innerText || '').trim();
    if (t && t.length < 60 && /[A-Za-z]/.test(t)) cands.push(t);
  });
  if (!cands.length) return '';
  var best = cands[0];
  cands.forEach(function(c){ if (c.length > best.length) best = c; });
  return best.split('\n')[0].trim();
})()
"@
    $current = (Invoke-CdpEval $jsName).Trim()
    $key = Get-StateKey $buyer
    $curKey = Get-StateKey $current
    $match = $curKey -and ($curKey -eq $key -or $current.IndexOf($buyer) -ge 0 -or $buyer.IndexOf($current) -ge 0)
    if (-not $match) { return "ABORT_WRONG_CONVO (expected=$buyer, current=$current)" }

    # 3) 填值(React 受控组件必须原生 setter + input 事件)
    $esc2 = $text.Replace("\","\\").Replace("'","\'").Replace("`n","\n").Replace("`r","\r")
    # 3+4+5) 合并:填值 + 点击发送 + 输入框清空校验 一次 eval(JS 内等待,P2.1a)
    $js2 = @"
(async function(){
  var ta = document.querySelector('textarea.send-textarea');
  if (!ta) return 'NO_TEXTAREA';
  var setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
  setter.call(ta, '$esc2');
  ta.dispatchEvent(new Event('input', {bubbles:true}));
  await new Promise(function(r){ setTimeout(r, 1000); });
  var btns = Array.from(document.querySelectorAll('button')).filter(function(b){ return (b.innerText||'').trim() === '发送'; });
  if (!btns.length) return 'FILLED|NO_BTN';
  btns[0].click();
  await new Promise(function(r){ setTimeout(r, 2000); });
  var ta2 = document.querySelector('textarea.send-textarea');
  return ta2 ? ('FILLED|CLICKED|LEN:' + ta2.value.length) : 'FILLED|CLICKED|NO_TA';
})()
"@
    $r2 = Invoke-CdpEval $js2
    if ($r2 -match 'LEN:0') { return "FILLED | CLICKED | SENT_OK" }
    return ($r2 -replace '\|',' | ') + " | NOT_SENT"
}
