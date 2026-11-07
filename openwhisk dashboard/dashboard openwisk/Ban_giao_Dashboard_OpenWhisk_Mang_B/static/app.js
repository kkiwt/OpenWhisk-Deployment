/* Results are fetched from the actual backend. No simulated measurements. */
const palette = { c1:'#6389ff', c2:'#29cabd', c3:'#aa8aff', c4:'#eeaf69' };
const paletteMore = ['#6389ff','#29cabd','#aa8aff','#ffb873','#ee7d9a','#92d97f','#67baf5','#cf98d4'];
const byId = id => document.getElementById(id);
const successValues = new Set(['ok','success','succeeded','completed','200','201','202']);
let lastStats = null, chartDefs = {}, charts = {}, pollBusy = false;

function fmt(n, places=0){return n===null || n===undefined ? '—' : Number(n).toLocaleString('vi-VN',{maximumFractionDigits:places,minimumFractionDigits:places});}
function humanClock(seconds){return new Date(seconds*1000).toLocaleTimeString('vi-VN',{hour:'2-digit',minute:'2-digit',second:'2-digit'});}
function safeColor(name,index){return palette[name] || paletteMore[index % paletteMore.length];}
function textEl(tag,text,klass=''){const e=document.createElement(tag);if(klass)e.className=klass;e.textContent=text;return e;}
function setConnection(connected){const elem=byId('connection');elem.classList.toggle('disconnected',!connected);elem.innerHTML=connected?'<span class="dot green"></span> Kết nối':'<span class="dot red"></span> Mất kết nối';}

function baseOptions(additional={}) { return {
  responsive:true,maintainAspectRatio:false,animation:false,interaction:{intersect:false,mode:'index'},
  plugins:{legend:{display:false},tooltip:{backgroundColor:'#1b2a42',titleColor:'#e5edff',bodyColor:'#c1d0e8',borderColor:'#425773',borderWidth:1,padding:11,displayColors:true}},
  scales:{x:{ticks:{color:'#71829e',font:{size:10},maxTicksLimit:9},grid:{display:false},border:{display:false}},y:{beginAtZero:true,ticks:{color:'#71829e',font:{size:10},precision:0},grid:{color:'#25344a'},border:{display:false}}},...additional
};}
function ensureChart(canvasId, type, data, options){
  const canvas=byId(canvasId); chartDefs[canvasId]={type,data,options};
  if(window.Chart){
    if(charts[canvasId] && !(charts[canvasId] instanceof window.Chart)){charts[canvasId]=null;}
    if(!charts[canvasId]) charts[canvasId]=new Chart(canvas,{type,data,options});
    else { charts[canvasId].data=data;charts[canvasId].options=options;charts[canvasId].update('none'); }
  } else {drawFallback(canvas, type, data);}
}

// Canvas fallback: dashboard still draws useful charts without CDN/Internet.
function drawFallback(canvas,type,data){
  const width=Math.max(canvas.parentElement.clientWidth,220),height=Math.max(canvas.parentElement.clientHeight,145);
  const dpr=window.devicePixelRatio||1;canvas.width=width*dpr;canvas.height=height*dpr;canvas.style.width=width+'px';canvas.style.height=height+'px';
  const ctx=canvas.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);
  const datasets=data.datasets || [],labels=data.labels||[];
  if(type==='doughnut'){
    const values=datasets[0]?.data||[];const total=values.reduce((a,b)=>a+b,0);
    const cx=width/2,cy=height/2,r=Math.min(width,height)*.32,thickness=r*.3;
    if(!total){ctx.strokeStyle='#29384e';ctx.lineWidth=thickness;ctx.beginPath();ctx.arc(cx,cy,r,0,Math.PI*2);ctx.stroke();return;}
    let angle=-Math.PI/2;values.forEach((v,i)=>{const slice=v/total*Math.PI*2;ctx.beginPath();ctx.strokeStyle=datasets[0].backgroundColor[i];ctx.lineWidth=thickness;ctx.arc(cx,cy,r,angle,angle+slice);ctx.stroke();angle+=slice;});
    ctx.fillStyle='#d8e4f8';ctx.font='700 22px system-ui';ctx.textAlign='center';ctx.fillText(String(total),cx,cy+5);return;
  }
  const pad={left:40,top:16,right:12,bottom:26},plotW=width-pad.left-pad.right,plotH=height-pad.top-pad.bottom;
  const values=datasets.flatMap(d=>d.data||[]);const max=Math.max(1,...values);
  ctx.lineWidth=1;ctx.font='10px system-ui';ctx.textAlign='right';
  for(let i=0;i<5;i++){const y=pad.top+i*plotH/4;ctx.strokeStyle='#25334a';ctx.beginPath();ctx.moveTo(pad.left,y);ctx.lineTo(width-pad.right,y);ctx.stroke();ctx.fillStyle='#7c8da8';ctx.fillText((max*(4-i)/4).toLocaleString('vi-VN',{maximumFractionDigits:2}),pad.left-8,y+3);}
  ctx.textAlign='center';ctx.fillStyle='#7488a4';
  const sparse=Math.max(1,Math.ceil(labels.length/7));labels.forEach((label,i)=>{if(i%sparse===0)ctx.fillText(String(label),pad.left+(labels.length===1?.5:i/Math.max(1,labels.length-1))*plotW,height-5);});
  if(type==='line'){
    datasets.forEach((d,k)=>{ctx.strokeStyle=d.borderColor||safeColor('c'+(k+1),k);ctx.lineWidth=2;ctx.beginPath();(d.data||[]).forEach((v,i)=>{const x=pad.left+i/Math.max(1,labels.length-1)*plotW,y=pad.top+(1-v/max)*plotH;i?ctx.lineTo(x,y):ctx.moveTo(x,y);});ctx.stroke();});
  }else{
    const group=plotW/Math.max(1,labels.length),barW=Math.max(2,Math.min(40,group*.76/Math.max(1,datasets.length)));
    datasets.forEach((d,k)=>(d.data||[]).forEach((v,i)=>{const x=pad.left+i*group+group*.12+k*barW,y=pad.top+(1-v/max)*plotH;ctx.fillStyle=Array.isArray(d.backgroundColor)?d.backgroundColor[i]:(d.backgroundColor||safeColor('c'+(k+1),k));ctx.fillRect(x,y,barW,Math.max(0,pad.top+plotH-y));}));
  }
}

function updateCharts(data){
  const clusters=Object.keys(data.clusters);
  const clusterNames=clusters.map(c=>c.toUpperCase());
  const raw=data.timeline.seconds;
  const bucketSize=data.window>300?15:data.window>60?5:1;
  const bucketStart=[];
  const times=[];
  for(let i=0;i<raw.length;i+=bucketSize){bucketStart.push(i);times.push(humanClock(raw[Math.min(i+bucketSize-1,raw.length-1)]));}
  const lines=clusters.map((c,i)=>({label:c.toUpperCase(),data:bucketStart.map(start=>data.timeline.by_cluster[c].slice(start,start+bucketSize).reduce((a,b)=>a+b,0)),borderColor:safeColor(c,i),backgroundColor:safeColor(c,i)+'19',tension:.32,pointRadius:0,borderWidth:2,fill:false}));
  ensureChart('timelineChart','line',{labels:times,datasets:lines},baseOptions());
  ensureChart('clusterChart','bar',{labels:clusterNames,datasets:[{label:'Số bản ghi',data:clusters.map(c=>data.clusters[c].count),backgroundColor:clusters.map(safeColor),borderRadius:5,maxBarThickness:55}]},baseOptions());
  ensureChart('latencyChart','bar',{labels:clusterNames,datasets:[{label:'Trung bình (ms)',data:clusters.map(c=>data.clusters[c].avg_ms),backgroundColor:clusters.map(safeColor),borderRadius:5,maxBarThickness:45}]},baseOptions({indexAxis:'y',scales:{x:{beginAtZero:true,ticks:{color:'#71829e',font:{size:10}},grid:{color:'#25344a'},border:{display:false}},y:{ticks:{color:'#a8b8d1',font:{size:12}},grid:{display:false},border:{display:false}}}}));
  const names=Object.keys(data.actions),vals=Object.values(data.actions);
  ensureChart('actionChart','doughnut',{labels:names.length?names:['No data'],datasets:[{data:vals.length?vals:[0],backgroundColor:names.length?names.map((_,i)=>paletteMore[i%paletteMore.length]):['#29384e'],borderWidth:0,hoverOffset:4}]},{responsive:true,maintainAspectRatio:false,animation:false,cutout:'77%',plugins:{legend:{display:false},tooltip:{enabled:names.length>0}}});
  const leg=byId('action-legend');leg.replaceChildren();
  if(!names.length){leg.append(textEl('span','Chưa có dữ liệu'));}
  names.slice(0,7).forEach((name,i)=>{const row=textEl('div','','leg'),label=textEl('span',name),dot=document.createElement('i');dot.style.background=paletteMore[i%paletteMore.length];label.prepend(dot);row.append(label,textEl('strong',String(vals[i])));leg.append(row);});
}

function updateSummary(s){
  const d=s.overview;
  byId('metric-total').textContent=fmt(d.count);
  byId('metric-rps').textContent=fmt(d.rps,2);
  byId('metric-latency').textContent=d.count?fmt(d.avg_ms,1):'—';
  byId('metric-p95').textContent=d.count?'P95: '+fmt(d.p95_ms,1)+' ms':'P95: — ms';
  byId('metric-success').textContent=d.success_rate===null?'—':fmt(d.success_rate,1);
  byId('metric-error').textContent=d.error_rate===null?'Chưa có dữ liệu':'Tỷ lệ lỗi '+fmt(d.error_rate,1)+'%';
  byId('record-count').textContent=fmt(s.stored)+' / '+fmt(s.max_records);
  byId('distribution-summary').textContent=d.count?'Đã nhận '+fmt(d.count)+' bản ghi trong '+(s.window===60?'60 giây':s.window/60+' phút'):'Chưa có bản ghi nào trong khoảng đã chọn';
  const container=byId('cluster-cards');container.replaceChildren();
  const clusters=Object.entries(s.clusters);const max=Math.max(1,...clusters.map(([,x])=>x.count));
  clusters.forEach(([c,x],i)=>{
    const card=textEl('article','','cluster-card');const top=textEl('div','','cluster-card-top');
    const name=textEl('div','','cluster-name');const glyph=textEl('span','⬡','cluster-glyph');glyph.style.color=safeColor(c,i);name.append(glyph,textEl('span','Cluster '+c.toUpperCase()));
    const chip=textEl('span',x.count?'Có bản ghi':'Chưa có bản ghi','cluster-tag'+(x.count?' seen':''));top.append(name,chip);
    const row=textEl('div','','cluster-stats');
    [['REQUESTS',fmt(x.count),''],['AVG LATENCY',x.count?fmt(x.avg_ms,1):'—','ms'],['SUCCESS',x.success_rate===null?'—':fmt(x.success_rate,1),'%']].forEach(([heading,val,suffix])=>{const b=textEl('div','','cluster-stat');b.append(textEl('span',heading),textEl('strong',val+(suffix?' '+suffix:'')));row.append(b);});
    const stripe=textEl('div','','cluster-stripe'),fill=document.createElement('span');fill.style.width=(x.count/max*100)+'%';fill.style.background=safeColor(c,i);stripe.append(fill);card.append(top,row,stripe);container.append(card);
  });
}
function updateRecent(items){
  const body=byId('recent-body');body.replaceChildren();
  if(!items.length){const tr=document.createElement('tr'),td=textEl('td','Chưa có bản ghi. Hệ thống sẽ hiển thị dữ liệu thực khi nhận POST /ingest.','empty-row');td.colSpan=6;tr.append(td);body.append(tr);return;}
  items.forEach(e=>{
    const tr=document.createElement('tr');tr.append(textEl('td',humanClock(e.received_at),'muted-cell'));
    tr.append(textEl('td',e.cluster.toUpperCase(),'cluster-badge '+e.cluster));
    tr.append(textEl('td',e.action));
    const req=textEl('td',e.req_id.length>17?e.req_id.slice(0,14)+'…':e.req_id,'mono');req.title=e.req_id;tr.append(req);
    const yes=successValues.has(String(e.status).toLowerCase()),t=document.createElement('td');t.append(textEl('span',e.status,'status '+(yes?'ok':'fail')));tr.append(t);
    tr.append(textEl('td',fmt(e.duration_ms,1)+' ms','numeric'));body.append(tr);
  });
}

async function refresh(){if(pollBusy)return;pollBusy=true;
  try{
    const w=Number(byId('windowSelect').value),cluster=byId('clusterFilter').value;
    const [r1,r2]=await Promise.all([fetch('/api/stats?window='+w,{cache:'no-store'}),fetch('/api/recent?limit=25&cluster='+encodeURIComponent(cluster),{cache:'no-store'})]);
    if(!r1.ok||!r2.ok)throw Error('API unavailable');
    const [stats,recent]=await Promise.all([r1.json(),r2.json()]);lastStats=stats;setConnection(true);updateSummary(stats);updateCharts(stats);updateRecent(recent.items);
    byId('updated-at').textContent='Cập nhật '+new Date().toLocaleTimeString('vi-VN');
  }catch(error){setConnection(false);byId('updated-at').textContent='Không thể cập nhật dữ liệu';console.error('Dashboard refresh:',error.message);
  }finally{pollBusy=false;}
}
byId('windowSelect').addEventListener('change',refresh);
byId('clusterFilter').addEventListener('change',refresh);
window.addEventListener('resize',()=>{if(!window.Chart){Object.entries(chartDefs).forEach(([id,x])=>drawFallback(byId(id),x.type,x.data));}});
setInterval(()=>{byId('clock').textContent=new Date().toLocaleTimeString('vi-VN',{hour:'2-digit',minute:'2-digit',second:'2-digit'});},1000);
refresh();setInterval(refresh,2000);
