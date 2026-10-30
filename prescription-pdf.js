(function(){
  'use strict';
  function text(v){return String(v==null?'':v).replace(/[\r\t]+/g,' ').trim();}
  function date(v){
    if(!v)return '—';
    const d=new Date(String(v).length===10?String(v)+'T00:00:00':v);
    return isNaN(d.getTime())?String(v):d.toLocaleDateString('en-IN',{day:'2-digit',month:'short',year:'numeric'});
  }
  function makePdf(record,patient){
    if(!window.jspdf||!window.jspdf.jsPDF)throw new Error('PDF engine could not load. Check your internet connection and try again.');
    const jsPDF=window.jspdf.jsPDF;
    const doc=new jsPDF({orientation:'portrait',unit:'mm',format:'a4',compress:true});
    const W=210,H=297,left=15,right=195,usable=180;
    const blue=[59,126,190],dark=[28,48,62],muted=[91,111,126],pale=[231,244,252],line=[153,190,220],white=[255,255,255];
    const p=patient||{};
    const name=text(record.patient_name||p.full_name||'Patient')||'Patient';
    const patientId=text(p.patient_code||record.patient_code||'');
    const phone=text(record.patient_phone||p.phone||'');
    const age=text(record.patient_age||p.age||'');
    const gender=text(record.patient_gender||p.gender||'');
    const allergies=text(record.patient_allergies||p.allergies||'');
    const visitDate=date(record.created_at||new Date().toISOString());
    let y=0;

    function drawLogo(){
      doc.setDrawColor.apply(doc,blue);doc.setLineWidth(1.15);
      doc.line(180,7,180,29);
      doc.line(180,9,165,6);doc.line(180,9,195,6);
      for(let i=0;i<4;i++){
        const yy=8+i*2.7;
        doc.line(179,yy,167-i*1.4,yy-1.7);
        doc.line(181,yy,193+i*1.4,yy-1.7);
      }
      doc.ellipse(176.5,16,3.5,2.2,'S');
      doc.ellipse(183.5,20,3.5,2.2,'S');
      doc.ellipse(176.5,24,3.5,2.2,'S');
    }
    function drawHeader(){
      doc.setFillColor.apply(doc,pale);doc.rect(0,0,W,39,'F');
      doc.setFillColor(255,255,255);doc.ellipse(82,-8,58,43,'F');
      doc.setTextColor.apply(doc,blue);doc.setFont('helvetica','bold');doc.setFontSize(19);
      doc.text('Prof. (Dr.) Mansoor Ahmad',14,17);
      doc.setTextColor.apply(doc,dark);doc.setFont('helvetica','normal');doc.setFontSize(9);
      doc.text('MBBS, MD PSYCHIATRY',15,25);
      doc.setFontSize(7.5);doc.setTextColor.apply(doc,muted);
      doc.text('Professor & HOD, Department of Psychiatry • GMC Anantnag',15,32);
      drawLogo();
      doc.setFontSize(7);doc.setTextColor.apply(doc,muted);
      doc.text('ExpectCare Clinic, Cheeni Chowk, Anantnag',15,44);
      doc.text('Phone: +91 9906927006  |  drmansoor.vercel.app',195,44,{align:'right'});
    }
    function drawContinuation(){
      doc.addPage();
      doc.setFillColor.apply(doc,pale);doc.rect(0,0,W,23,'F');
      doc.setTextColor.apply(doc,blue);doc.setFont('helvetica','bold');doc.setFontSize(12);
      doc.text('Prof. (Dr.) Mansoor Ahmad',15,11);
      doc.setFont('helvetica','normal');doc.setFontSize(8);doc.setTextColor.apply(doc,dark);
      doc.text('Prescription continued  •  '+name,15,17);
      return 31;
    }
    function rule(yPos){doc.setDrawColor.apply(doc,line);doc.setLineWidth(.35);doc.line(left,yPos,right,yPos);}
    function field(label,value,x,yPos,width){
      doc.setFont('helvetica','bold');doc.setFontSize(8);doc.setTextColor.apply(doc,dark);doc.text(label+':',x,yPos);
      doc.setFont('helvetica','normal');doc.setFontSize(8);doc.setTextColor.apply(doc,dark);
      const start=x+doc.getTextWidth(label+': ')+1;
      const lines=doc.splitTextToSize(text(value)||'—',Math.max(12,width-(start-x)));
      doc.text(lines,start,yPos);
      rule(yPos+2.2);
    }
    function watermark(){
      doc.setDrawColor(238,247,252);doc.setLineWidth(3);
      doc.line(105,151,105,212);
      doc.line(105,157,75,148);doc.line(105,157,135,148);
      for(let i=0;i<4;i++){
        const yy=158+i*6;
        doc.line(104,yy,78-i*2,yy-3);
        doc.line(106,yy,132+i*2,yy-3);
      }
      doc.setLineWidth(2.5);
      doc.ellipse(99,181,8,12,'S');doc.ellipse(111,190,8,12,'S');
      doc.ellipse(99,202,7,10,'S');doc.ellipse(111,209,7,8,'S');
    }
    function sectionTitle(title,yPos){
      doc.setFont('helvetica','bold');doc.setFontSize(9);doc.setTextColor.apply(doc,blue);
      doc.text(title.toUpperCase(),left,yPos);
      return yPos+6;
    }
    function addParagraph(title,value){
      const val=text(value)||'—';
      doc.setFont('helvetica','normal');doc.setFontSize(8.5);
      const lines=doc.splitTextToSize(val,usable);
      let needed=8+lines.length*4.2;
      if(y+needed>266)y=drawContinuation();
      y=sectionTitle(title,y);
      doc.setFont('helvetica','normal');doc.setFontSize(8.5);doc.setTextColor.apply(doc,dark);
      doc.text(lines,left,y);
      y+=lines.length*4.2+4;
    }
    function tableHeader(){
      const widths=[46,28,31,38,37];
      const labels=['MEDICINE','STRENGTH','DOSE','FREQUENCY','DURATION'];
      doc.setFillColor.apply(doc,blue);doc.roundedRect(left,y,usable,8,1.2,1.2,'F');
      doc.setFont('helvetica','bold');doc.setFontSize(7);doc.setTextColor.apply(doc,white);
      let x=left;
      labels.forEach((lab,i)=>{doc.text(lab,x+2,y+5.2);x+=widths[i]});
      y+=8;
      return widths;
    }
    function addMeds(){
      const rows=Array.isArray(record.medication_items)?record.medication_items:[];
      const fallback=text(record.medicines).split('\n').filter(Boolean).map(v=>({name:v,strength:'',dose:'',frequency:'',duration:''}));
      const meds=rows.length?rows:fallback;
      y=sectionTitle('Prescription / Rx',y);
      doc.setFont('helvetica','bold');doc.setFontSize(22);doc.setTextColor.apply(doc,blue);doc.text('Rx',left,y+5);
      y+=13;
      const widths=tableHeader();
      meds.forEach((m)=>{
        const vals=[m.name,m.strength,m.dose,m.frequency,m.duration].map(v=>text(v)||'—');
        const wrapped=vals.map((v,i)=>doc.splitTextToSize(v,widths[i]-4));
        const rowH=Math.max(8,...wrapped.map(a=>a.length*3.5+3));
        if(y+rowH>266){y=drawContinuation();tableHeader();}
        doc.setDrawColor(220,231,239);doc.setLineWidth(.25);doc.line(left,y+rowH,right,y+rowH);
        let x=left;
        wrapped.forEach((lines,i)=>{
          doc.setFont('helvetica',i===0?'bold':'normal');doc.setFontSize(7.5);
          doc.setTextColor.apply(doc,dark);doc.text(lines,x+2,y+4.7);
          x+=widths[i];
        });
        y+=rowH;
      });
      y+=7;
    }
    function drawFooter(){
      const pageCount=doc.getNumberOfPages();
      for(let n=1;n<=pageCount;n++){
        doc.setPage(n);
        doc.setFillColor.apply(doc,pale);doc.rect(0,276,W,21,'F');
        doc.setDrawColor.apply(doc,blue);doc.setLineWidth(1.1);doc.line(73,279,73,294);
        doc.setFont('helvetica','bold');doc.setFontSize(10);doc.setTextColor.apply(doc,blue);
        doc.text('EXPECTCARE',15,286);
        doc.setFont('helvetica','normal');doc.setFontSize(6.8);doc.setTextColor.apply(doc,dark);
        doc.text('Psychiatry & Mental Healthcare',15,291);
        doc.setFont('helvetica','bold');doc.setFontSize(7);doc.text('CONTACT',80,283);
        doc.setFont('helvetica','normal');doc.setFontSize(7);
        doc.text('+91 9906927006  •  Cheeni Chowk, Anantnag',80,288);
        doc.setTextColor.apply(doc,blue);doc.text('https://drmansoor.vercel.app',80,293);
        doc.setTextColor.apply(doc,muted);doc.setFontSize(6.5);
        doc.text('Page '+n+' of '+pageCount,195,271,{align:'right'});
      }
    }

    drawHeader();
    doc.setFont('helvetica','bold');doc.setFontSize(8);doc.setTextColor.apply(doc,dark);
    doc.text('PATIENT DETAILS',15,56);
    field('Patient Name',name,15,64,180);
    field('Patient ID',patientId||'Not assigned',15,74,87);
    field('Date',visitDate,108,74,87);
    field('Mobile',phone||'—',15,84,87);
    field('Age / Gender',[age?age+' years':'',gender].filter(Boolean).join(' / ')||'—',108,84,87);
    field('Diagnosis',text(record.diagnosis)||'—',15,94,180);
    y=108;
    watermark();
    addMeds();
    if(record.complaints)addParagraph('Chief complaints',record.complaints);
    if(record.vitals&&Object.keys(record.vitals).length)addParagraph('Vitals',Object.keys(record.vitals).map(k=>k+': '+record.vitals[k]).join('   •   '));
    if(allergies)addParagraph('Known allergies',allergies);
    if(record.advice)addParagraph('Advice / instructions',record.advice);
    if(record.follow_up_date)addParagraph('Follow-up',date(record.follow_up_date));
    if(y+30>268)y=drawContinuation();
    doc.setDrawColor.apply(doc,line);doc.setLineWidth(.45);doc.line(133,y+10,195,y+10);
    doc.setFont('helvetica','bold');doc.setFontSize(8);doc.setTextColor.apply(doc,dark);
    doc.text('Prof. (Dr.) Mansoor Ahmad',195,y+16,{align:'right'});
    doc.setFont('helvetica','normal');doc.setFontSize(7);doc.setTextColor.apply(doc,muted);
    doc.text('MBBS, MD Psychiatry  •  Signature / Seal',195,y+21,{align:'right'});
    drawFooter();
    const clean=name.replace(/[^a-z0-9]+/gi,'_').replace(/^_+|_+$/g,'')||'Patient';
    const stamp=String(record.created_at||new Date().toISOString()).slice(0,10);
    doc.save('Prescription_'+clean+'_'+stamp+'.pdf');
  }
  window.generateClinicPrescriptionPdf=makePdf;
})();