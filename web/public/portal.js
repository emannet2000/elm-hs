'use strict';
(async () => {
  const notice=document.getElementById('notice'),root=document.getElementById('content');
  const fragment=location.hash.slice(1);
  if(fragment){sessionStorage.setItem('ecc-portal',fragment);history.replaceState(null,'',location.pathname);}
  const token=sessionStorage.getItem('ecc-portal');
  const e=(tag,text)=>{const n=document.createElement(tag);if(text)n.textContent=text;return n;};
  const add=(p,...children)=>{children.forEach(n=>p.append(n));return p;};
  const panel=(title,...children)=>{const p=e('section');p.className='panel';return add(p,e('h2',title),...children);};
  const field=(label,node)=>add(e('label',label),node);
  async function api(path,body){const response=await fetch(path,{method:body?'POST':'GET',headers:{'X-Portal-Token':token,...(body&&!(body instanceof FormData)?{'Content-Type':'application/json'}:{})},body:body instanceof FormData?body:body?JSON.stringify(body):undefined});const result=await response.json();if(!response.ok)throw new Error(result.error||'Request failed');return result;}
  async function load(){
    const data=await api('/api/portal');root.replaceChildren(e('h2',`Welcome, ${data.client.full_name}`));root.setAttribute('aria-busy','false');
    data.cases.forEach(c=>{const p=panel(`${c.service_category||'Application'} · ${c.destination||''}`,e('p',`Status: ${c.stage}`),e('p',c.next_action?`Next step: ${c.next_action}`:'Your consultant will update your next step.'),e('p',c.next_deadline?`Next deadline: ${c.next_deadline}`:''));data.requirements.filter(r=>r.case_id===c.id).forEach(r=>add(p,e('p',`${r.ready?'✓':'○'} ${r.title}${r.category?' · '+r.category:''}`)));root.append(p);});
    const docs=panel('Your documents');data.documents.forEach(d=>add(docs,e('h3',d.filename),e('p',`${d.category} · ${d.review_status}${d.rejection_reason?' · '+d.rejection_reason:''}${d.expires_on?' · Expires '+d.expires_on:''}`)));root.append(docs);
    const upload=e('form'),file=e('input');Object.assign(file,{type:'file',name:'file',required:true,accept:'.pdf,.jpg,.jpeg,.png'});
    const category=e('select');category.name='category';const categories=[...new Set(['Other',...data.requirements.map(r=>r.category).filter(Boolean)])];categories.forEach(c=>{const o=e('option',c);o.value=c;category.append(o);});
    const submit=e('button','Upload document');submit.type='submit';add(upload,field('Document category',category),field('PDF, JPEG or PNG · Maximum 25 MB',file),submit);
    upload.onsubmit=async ev=>{ev.preventDefault();submit.disabled=true;try{if(file.files[0].size>25*1024*1024)throw new Error('File must be no larger than 25 MB.');await api('/api/portal/documents',new FormData(upload));notice.textContent='Document uploaded. Your consultant will review it.';await load();}catch(err){notice.textContent=err.message;}finally{submit.disabled=false;}};
    root.append(panel('Send a document',upload));
    const form=e('form'),body=e('textarea');body.name='body';body.required=true;body.maxLength=10000;const send=e('button','Send message');send.type='submit';add(form,field('Message to your consultant',body),send);form.onsubmit=async ev=>{ev.preventDefault();send.disabled=true;try{await api('/api/portal/messages',{body:body.value});notice.textContent='Message sent to your consultant.';await load();}catch(err){notice.textContent=err.message;}finally{send.disabled=false;}};const conversation=panel('Messages with ECC');(data.messages||[]).forEach(m=>add(conversation,e('h3',m.sender),e('p',m.body),e('p',new Date(m.created_at).toLocaleString())));root.append(conversation,panel('Contact your consultant',form));
    const end=e('button','Close portal');end.onclick=()=>{sessionStorage.removeItem('ecc-portal');location.reload();};root.append(end);
  }
  try{if(!token)throw new Error('Open the private link provided by your consultant.');await load();}catch(err){notice.textContent=err.message;root.textContent='Contact ECC for a new link if yours has expired.';root.setAttribute('aria-busy','false');}
})();
