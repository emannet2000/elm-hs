'use strict';
(() => {
  const $ = id => document.getElementById(id);
  if (new URLSearchParams(location.search).get('dark') === '1' || localStorage.getItem('ecc-dark') === '1') document.body.classList.add('app-shell--dark');
  const token = localStorage.getItem('ecc-token');
  let data, selectedCase = new URLSearchParams(location.search).get('case') || '', tab = new URLSearchParams(location.search).get('tab') || 'cases';
  const tabs = { cases:'Applications', tasks:'Tasks', documents:'Documents', reminders:'Reminders', contacts:'Communications', reports:'Reports', billing:'Invoices & payments', portal:'Client access', settings:'Administration' };
  const e = (tag, text, cls) => { const n=document.createElement(tag); if(text!==null&&text!==undefined)n.textContent=String(text); if(cls)n.className=cls; return n; };
  const add = (parent,...nodes) => { nodes.flat().filter(Boolean).forEach(n=>parent.append(n)); return parent; };
  const notice = (msg,error=false) => { $('notice').textContent=msg; $('notice').className=error?'error':''; };
  const button = (text,action,cls='') => { const n=e('button',text,cls); n.type='button'; n.onclick=async()=>{n.disabled=true;try{await action();}catch(err){notice(err.message,true);}finally{n.disabled=false;}};return n; };
  const panel = (title,...nodes) => add(e('section',null,'panel'),e('h2',title),...nodes);
  const badge = (text,good=false) => e('span',text,'badge '+(good?'good':''));
  const option = (value,label) => {const n=e('option',label);n.value=value;return n;};
  const choices = (name,items,value='',blank=true) => {const n=e('select');n.name=name;if(blank)n.append(option('','Select…'));items.forEach(x=>n.append(option(x[0],x[1])));n.value=String(value??'');return n;};
  const input = (name,type='text',value='',required=true) => {const n=e('input');Object.assign(n,{name,type,value:value??'',required});if(type==='number'){n.min='1';n.step='1';n.max='9007199254740991';}return n;};
  const field = (label,node,required=false) => {node.required=required;return add(e('label',label),node);};
  const txt = (name,label,value='',required=true,type='text') => field(label,input(name,type,value,required),required);
  const fields = (...nodes) => add(e('div',null,'fields'),...nodes);
  const clients = () => data.clients.map(c=>[c.id,`${c.client_number} · ${c.full_name}`]);
  const cases = () => data.cases.map(c=>[c.id,`#${c.id} · ${clientName(c.client_id)} · ${c.service_category||'Application'}`]);
  const users = () => data.users.map(u=>[u.id,u.name]);
  const clientName = id => data.clients.find(c=>c.id===id)?.full_name || `Client #${id}`;
  const targetName = r => r.case_id?`Case #${r.case_id} · ${clientName(data.cases.find(c=>c.id===r.case_id)?.client_id)}`:r.client_id?clientName(r.client_id):data.leads.find(l=>l.id===r.lead_id)?.full_name||'Unlinked';
  const money = (minor,currency) => new Intl.NumberFormat(undefined,{style:'currency',currency}).format(Number(minor)/100);
  const form = (op,body,extra={},after) => {const f=e('form');add(f,body,e('button','Save','primary'));f.lastChild.type='submit';f.onsubmit=async ev=>{ev.preventDefault();const b=f.lastChild;b.disabled=true;try{const p={...Object.fromEntries(new FormData(f)),...extra};const result=await api(`/api/operations/${op}`,p);notice('Saved.');if(after)await after(result);else await load();}catch(err){notice(err.message,true);}finally{b.disabled=false;}};return f;};
  async function api(path,body){const r=await fetch(path,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${token}`,...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});const value=await r.json();if(!r.ok)throw new Error(value.error||'Request failed');return value;}
  async function command(op,p){await api(`/api/operations/${op}`,p);notice('Saved.');await load();}
  const table = (headers,rows) => {const t=e('table');add(t,add(e('thead'),add(e('tr'),headers.map(h=>e('th',h)))));const b=e('tbody');rows.forEach(row=>add(b,add(e('tr'),row.map(v=>add(e('td'),v instanceof Node?v:document.createTextNode(String(v??'—')))))));if(!rows.length)add(b,add(e('tr'),e('td','No records yet.')));return add(e('div',null,'table-scroll'),add(t,b));};
  const targetFields = () => fields(field('Lead',choices('lead_id',data.leads.map(l=>[l.id,l.full_name]))),field('Client',choices('client_id',clients())),field('Application',choices('case_id',cases())));
  const readonly = () => data.user.role==='viewer';
  const canAdmin = () => data.user.role==='admin';
  const group = (rows,key) => {const m=new Map();rows.forEach(r=>{const k=key(r)||'Unspecified';m.set(k,(m.get(k)||0)+1);});return [...m];};

  function render(){
    $('tabs').replaceChildren(...Object.entries(tabs).filter(([k])=>k!=='settings'||canAdmin()).map(([k,v])=>button(v,()=>{tab=k;render();},k===tab?'active':'')));
    const content=$('content');content.replaceChildren();content.setAttribute('aria-busy','false');
    ({cases:renderCases,tasks:renderTasks,documents:renderDocuments,reminders:renderReminders,contacts:renderContacts,reports:renderReports,billing:renderBilling,portal:renderPortal,settings:renderSettings}[tab]||renderCases)(content);
    if(readonly())content.querySelectorAll('form').forEach(f=>{f.remove();});
    resize();
  }
  function renderCases(root){
    const picker=choices('case',cases(),selectedCase);picker.onchange=()=>{selectedCase=picker.value;render();};
    add(root,fields(field('Application',picker)));
    const c=data.cases.find(c=>String(c.id)===selectedCase);
    if(!c){add(root,panel('Applications',table(['Application','Client','Service','Stage','Deadline'],data.cases.map(c=>[button(`#${c.id}`,()=>{selectedCase=String(c.id);render();}),clientName(c.client_id),c.service_category,c.stage,c.next_deadline]))));return;}
    const requirements=data.requirements.filter(r=>r.case_id===c.id),ready=requirements.filter(r=>r.ready).length;
    if(canAdmin())add(root,panel('Case ownership',form('handoff',fields(field('Case officer',choices('officer_id',users(),data.clients.find(x=>x.id===c.client_id)?.case_officer_id),true)),{client_id:c.client_id})));
    add(root,panel(`${clientName(c.client_id)} · ${c.service_category||'Application'}`,e('p',`${ready} of ${requirements.length} requirements ready. ${requirements.length?'Outstanding requirements block stage changes.':'Add requirements or configure a service template.'}`),form('case',fields(field('Stage',choices('stage',['Documents Under Review','Submitted','Decision Pending','Approved','Rejected','Completed','Cancelled'].map(s=>[s,s]),c.stage,false)),txt('next_deadline','Next deadline',c.next_deadline,false,'date'),txt('next_action','Next action',c.next_action,false)),{id:c.id})));
    const list=panel('Application checklist');
    requirements.forEach(r=>{
      const docs=data.documents.filter(d=>d.client_id===c.client_id&&(!r.category||d.category===r.category));
      const status=choices('completed',[[true,'Complete'],[false,'Outstanding']],r.completed,false);
      add(list,panel(r.title,badge(r.ready?'Ready':'Outstanding',r.ready),form('completeRequirement',fields(field('Completion',status),field('Evidence document',choices('document_id',docs.map(d=>[d.id,`${d.filename} · ${d.review_status}`]),r.document_id))),{id:r.id})));
      if(canAdmin())add(list,button('Remove '+r.title,()=>{if(confirm('Remove this requirement from the application?'))return command('removeRequirement',{id:r.id});}));
    });
    add(list,form('requirement',fields(txt('title','New requirement'),txt('category','Document category (leave blank for a step)','',false)),{case_id:c.id}));add(root,list);
    add(root,panel('Case history',table(['When','Event','Details'],data.history.filter(h=>h.case_id===c.id).map(h=>[new Date(h.created_at).toLocaleString(),h.event,e('pre',JSON.stringify(h.details,null,2))]))));
  }
  function renderTasks(root){
    add(root,panel('Assign work',e('p','Choose exactly one lead, client or application. Converted leads retain their outstanding tasks under the client.'),form('task',add(e('div'),targetFields(),fields(txt('title','Task title'),txt('description','Details','',false),txt('due_date','Due date','',false,'date'),field('Priority',choices('priority',[['Low','Low'],['Medium','Medium'],['High','High']],'Medium',false)),field('Assignee',choices('assigned_to_id',users(),data.user.id)))))));
    add(root,panel('Open and completed tasks',table(['Task','Record','Due','Assignee','Status'],data.tasks.map(t=>[t.title,targetName(t),t.due_date,data.users.find(u=>u.id===t.assigned_to_id)?.name,readonly()?t.status:button(t.status,()=>command('taskStatus',{id:t.id,status:t.status==='Done'?'Pending':t.status==='Pending'?'In Progress':'Done'}))]))));
  }
  function renderDocuments(root){
    add(root,panel('Upload a document',e('p','Attach files to a lead or client from their record. The client portal also accepts PDF, JPEG and PNG files.')));
    data.documents.forEach(d=>{
      const link=e('a','Download');link.href=`/api/documents/${d.id}/download?token=${encodeURIComponent(token)}`;link.rel='noreferrer';
      const older=data.documents.filter(x=>x.id<d.id&&x.client_id===d.client_id&&x.lead_id===d.lead_id);
      add(root,panel(`${d.filename} · ${targetName(d)}`,badge(data.documents.some(x=>x.replaces_id===d.id)?'Superseded':d.review_status,d.review_status==='Approved'),e('p',`${d.category}${d.expires_on?' · Expires '+d.expires_on:''}${d.rejection_reason?' · '+d.rejection_reason:''}`),link,form('document',fields(txt('category','Category',d.category),field('Review status',choices('review_status',[['Pending','Pending'],['Approved','Approved'],['Rejected','Rejected']],d.review_status,false)),txt('rejection_reason','Rejection reason',d.rejection_reason,false),txt('expires_on','Expiry date',d.expires_on,false,'date'),field('Replaces an earlier document',choices('replaces_id',older.map(x=>[x.id,x.filename]),d.replaces_id))),{id:d.id})));
    });
    if(!data.documents.length)add(root,e('p','No documents uploaded yet.'));
  }
  function renderReminders(root){
    add(root,panel('Reminder inbox',e('p','The server checks every minute for follow-ups, tasks and case deadlines. Unread reminders escalate to administrators after one day.')));
    add(root,panel('Reminder history',table(['Created','Reminder','State',''],data.notifications.map(n=>{const link=e('a',n.title);link.href=n.href;link.target='_top';return [new Date(n.created_at).toLocaleString(),link,n.escalated?'Escalated':n.resolved_at?'Resolved':n.read_at?'Read':'Unread',n.read_at?'':button('Mark read',()=>command('readNotification',{id:n.id}))];}))));
  }
  function renderContacts(root){
    const body=e('textarea');body.name='body';body.required=true;body.maxLength=10000;
    const template=choices('template',data.messageTemplates.map(t=>[t.id,t.title]));template.onchange=()=>{body.value=data.messageTemplates.find(t=>String(t.id)===template.value)?.body||'';};
    add(root,panel('Log a conversation',e('p','Choose one related record. Choose portal visibility to share a message with the client. Email delivery requires your communication service.'),form('communication',add(e('div'),targetFields(),fields(field('Type',choices('kind',['Note','Call','Email','Message'].map(k=>[k,k]),'Note',false)),field('Use a template',template),field('Client portal visibility',choices('portal_visible',[[false,'Internal history only'],[true,'Share in client portal']],false,false))),field('Summary or message',body,true)))));
    add(root,panel('Communication history',table(['When','Record','Type','Message'],data.communications.map(c=>[new Date(c.created_at).toLocaleString(),targetName(c),c.kind,c.body]))));
  }
  function renderReports(root){
    const from=input('from','date','',false),to=input('to','date','',false);
    const results=e('div');const draw=()=>{
      const leads=data.leads.filter(l=>(!from.value||l.created_at.slice(0,10)>=from.value)&&(!to.value||l.created_at.slice(0,10)<=to.value));
      const converted=leads.filter(l=>l.stage==='Converted').length;
      const today=new Date().toISOString().slice(0,10);
      const overdue=data.cases.filter(c=>c.next_deadline&&c.next_deadline<today&&!['Completed','Cancelled','Closed/Lost'].includes(c.stage));
      const metric=(label,value)=>add(e('div',null,'metric'),e('span',label),e('strong',value));
      results.replaceChildren(add(e('div',null,'stats'),metric('Leads in period',leads.length),metric('Conversion rate',`${leads.length?Math.round(converted/leads.length*100):0}%`),metric('Overdue cases',overdue.length),metric('Open tasks',data.tasks.filter(t=>t.status!=='Done').length)));
      add(results,panel('Lead sources',table(['Source','Leads'],group(leads,l=>l.source))),panel('Consultant workload',table(['Consultant','Leads','Clients','Open tasks'],data.users.map(u=>[u.name,data.leads.filter(l=>l.consultant_id===u.id&&l.stage!=='Converted').length,data.clients.filter(c=>c.case_officer_id===u.id).length,data.tasks.filter(t=>t.assigned_to_id===u.id&&t.status!=='Done').length]))),panel('Overdue applications',table(['Application','Client','Stage','Deadline'],overdue.map(c=>[c.id,clientName(c.client_id),c.stage,c.next_deadline]))));
      const durations=[];
      data.cases.forEach(c=>{const events=data.history.filter(h=>h.case_id===c.id&&h.details.after).sort((a,b)=>new Date(a.created_at)-new Date(b.created_at));let stage=null,start=null;events.forEach(h=>{const next=h.details.after.stage;if(next!==stage){if(stage&&start)durations.push({stage,days:(new Date(h.created_at)-start)/86400000});stage=next;start=new Date(h.created_at);}});if(stage&&start)durations.push({stage,days:(Date.now()-start)/86400000});});
      add(results,panel('Time in application stages',e('p','Measured from recorded stage changes after workflow tracking was enabled; the current stage includes elapsed time to today.'),table(['Stage','Average days','Recorded visits'],group(durations,r=>r.stage).map(([stage,n])=>[stage,(durations.filter(d=>d.stage===stage).reduce((a,d)=>a+d.days,0)/n).toFixed(1),n]))));
    };from.onchange=draw;to.onchange=draw;add(root,panel('Report period',e('p','Dates filter the lead cohort and source report. Workload and overdue cases reflect the current workspace.'),fields(field('From',from),field('To',to))),results);draw();
  }
  function renderBilling(root){
    add(root,panel('Create invoice',form('invoice',fields(field('Client',choices('client_id',clients()),true),txt('description','Service / description'),txt('currency','Currency code','PHP'),txt('amount_minor','Amount in minor units (100 = 1.00)','',true,'number'),txt('due_date','Due date','',true,'date')))));
    data.invoices.forEach(i=>{
      const p=panel(`#${i.id} · ${clientName(i.client_id)}`,e('p',i.description),e('h3',`${money(i.amount_minor,i.currency)} · Outstanding ${money(Number(i.amount_minor)-Number(i.paid_minor),i.currency)}`),e('p',`Due ${i.due_date}`));
      add(p,form('payment',fields(txt('amount_minor','Payment in minor units','',true,'number'),txt('reference','Unique receipt / transaction reference'),txt('received_on','Received on',new Date().toISOString().slice(0,10),true,'date')),{invoice_id:i.id}),form('installment',fields(txt('amount_minor','Installment in minor units','',true,'number'),txt('due_date','Installment due','',true,'date')),{invoice_id:i.id}),table(['Installment','Due'],data.installments.filter(x=>x.invoice_id===i.id).map(x=>[money(x.amount_minor,i.currency),x.due_date])),table(['Receipt','Date','Amount',''],data.payments.filter(x=>x.invoice_id===i.id).map(x=>[x.reference,x.received_on,money(x.amount_minor,i.currency),button('View receipt',()=>{root.replaceChildren(panel('ECC · Payment receipt',e('h3',x.reference),e('p',clientName(i.client_id)),e('p',`Invoice #${i.id} · ${i.description}`),e('p',`Received ${money(x.amount_minor,i.currency)} on ${x.received_on}`),button('Print',()=>window.print()),button('Back',()=>render())));})])));add(root,p);
    });
  }
  function renderPortal(root){
    const output=e('div');
    add(root,panel('Invite a client',e('p','Links expire after seven days. Anyone with a link can view that client’s progress, upload documents and send messages. Share it privately.'),form('portalLink',fields(field('Client',choices('client_id',clients()),true)),{},async result=>{const url=new URL('/portal.html',location.origin);url.hash=result.token;output.replaceChildren(e('p','Copy and privately share this link. It is shown once.'),e('div',url.href,'link-output'));resize();}),output));
    add(root,panel('Manage client links',table(['Client','Expires','State',''],data.portalLinks.map(p=>[clientName(p.client_id),new Date(p.expires_at).toLocaleString(),p.revoked_at?'Revoked':new Date(p.expires_at)<new Date()?'Expired':'Active',p.revoked_at||readonly()?'':button('Revoke',()=>command('revokePortal',{id:p.id}))]))));
  }
  function renderSettings(root){
    if(!canAdmin())return;
    add(root,panel('Record access',e('p','Administrators and viewers can read all records. Consultants can use either all records or only records assigned to them. Reassignment and merges require an administrator.'),form('settings',fields(field('Consultant scope',choices('consultant_scope',[['all','All records'],['assigned','Assigned records only']],data.settings.consultant_scope,false))))));
    add(root,panel('Requirement templates',e('p','Templates apply to matching applications, including existing cases. Use * for all destinations. Review requirements before staff advance cases.'),form('template',fields(txt('service','Service (exact name)'),txt('destination','Destination','*'),txt('title','Requirement title'),txt('category','Required document category (blank for a step)','',false))),table(['Service','Destination','Requirement','Category'],data.templates.map(t=>[t.service,t.destination,t.title,t.category]))));
    data.templates.forEach(t=>add(root,panel(t.title,form('updateTemplate',fields(txt('service','Service',t.service),txt('destination','Destination',t.destination),txt('title','Requirement title',t.title),txt('category','Category',t.category,false)),{id:t.id}),button('Retire template',()=>{if(confirm('Retire this template? Existing case requirements will remain until an administrator removes them.'))return command('retireTemplate',{id:t.id});}))));
    add(root,panel('Communication templates',form('messageTemplate',fields(txt('title','Template title'),txt('body','Template text')))));
    const kind=choices('kind',[['lead','Leads'],['client','Clients']],'lead',false),source=choices('id',[]),target=choices('target_id',[]);
    const pick=()=>{const rows=kind.value==='lead'?data.leads.filter(l=>!l.converted_client_id):data.clients;[source,target].forEach(s=>s.replaceChildren(option('','Select…'),...rows.map(r=>option(r.id,`#${r.id} · ${r.full_name}`))));};kind.onchange=pick;pick();
    const merge=form('merge',fields(field('Record type',kind),field('Merge this record',source,true),field('Into this record',target,true)));
    const original=merge.onsubmit;merge.onsubmit=ev=>{ev.preventDefault();if(confirm(`Merge #${source.value} into #${target.value}? The source record will be removed and related work moved. The destination keeps its contact details. Existing client portal links will be revoked.`))original(ev);};
    add(root,panel('Review and merge duplicates',e('p','New matching email addresses and normalized phone numbers are blocked during entry and CSV import. Review existing duplicates before merging; the destination keeps its contact details.'),merge));
    const matches=[];['leads','clients'].forEach(k=>{const rows=data[k];for(let a=0;a<rows.length;a++)for(let b=a+1;b<rows.length;b++){const x=rows[a],y=rows[b],em=v=>(v||'').trim().toLowerCase(),ph=v=>(v||'').replace(/\D/g,'');if((em(x.email)&&em(x.email)===em(y.email))||(ph(x.phone)&&ph(x.phone)===ph(y.phone)))matches.push([k,`#${x.id} ${x.full_name}`,`#${y.id} ${y.full_name}`]);}});
    add(root,panel('Potential duplicates',table(['Type','Record','Matching record'],matches)));
  }
  async function load(){data=await api('/api/operations');render();}
  function resize(){requestAnimationFrame(()=>{if(window.parent!==window)window.parent.postMessage({type:'ecc-workflow-height',height:document.documentElement.scrollHeight},location.origin);});}
  $('refresh').onclick=()=>load().catch(err=>notice(err.message,true));
  if(!token){notice('Sign in to ECC CRM to open the workspace.',true);$('content').replaceChildren(add(e('a','Sign in'),document.createTextNode('')));$('content').firstChild.href='/';}
  else load().catch(err=>{notice(err.message,true);$('content').textContent='Could not load the workspace. Use Refresh to try again.';});
})();
