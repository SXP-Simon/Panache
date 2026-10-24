const fs=require('node:fs');
const path=require('node:path');
const {test,expect,openHome,useSmallCanvas,expectPreviewImageLoaded}=require('./fixtures');
const png=fs.readFileSync(path.join(__dirname,'../fixtures/inline-mark.png'));

function deferred(){let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};}
async function transport(page,{holdCreate=false,failOnce=false,lateResult=false,initialComplete=false}={}){
  const creation=deferred(),completion=deferred(),result=deferred();
  let count=0,cancels=0,finished=false,resultCalls=0;
  const ids=[];
  await page.routeWebSocket('**/api/generate_handwriting/ws/**',socket=>socket.close());
  await page.route('**/api/generate_handwriting',async route=>{
    count++;
    const id=route.request().headers()['x-panache-task-id'];
    ids.push(id);
    if(holdCreate && count===1)await creation.promise;
    await route.fulfill({json:{task_id:id}});
  });
  await page.route('**/api/generate_handwriting/task/**',async route=>{
    const url=route.request().url();
    const first=url.includes(`/task/${ids[initialComplete?1:0]}`);
    if(url.endsWith('/cancel')){
      cancels++;
      if(failOnce && cancels===1){await route.abort();return;}
      await route.fulfill({json:{task_status:'cancelling'}});return;
    }
    if(url.endsWith('/result')){
      resultCalls++;
      if(first && lateResult)await result.promise;
      await route.fulfill({contentType:'image/png',body:png});return;
    }
    if(first && cancels>0 && !(failOnce&&cancels===1))await completion.promise;
    await route.fulfill({json:{task_status:first ? (finished?'cancelled':lateResult?'completed':'processing'):'completed'}});
  });
  return {creation,result,cancels:()=>cancels,resultCalls:()=>resultCalls,count:()=>count,finish(){finished=true;completion.resolve();}};
}

for(const options of [{holdCreate:true},{failOnce:true},{lateResult:true}]){
 test(`stop holds lock and discards old results ${JSON.stringify(options)}`,async({page})=>{
  const server=await transport(page,options);
  await openHome(page);
  await useSmallCanvas(page);
  await page.getByTestId('text-input').fill('取消测试，保留正文');
  await page.getByTestId('preview-btn').click();
  if(options.lateResult)await expect.poll(server.resultCalls).toBe(1);
  await page.getByTestId('cancel-generation-btn').click();
  if(options.holdCreate) await expect.poll(server.cancels).toBe(1);
  await expect.poll(server.cancels).toBe(1);
  await expect(page.getByTestId('preview-btn')).toBeDisabled();
  if(options.failOnce){
    await expect(page.getByTestId('message-info')).toContainText('尚未确认');
    await page.getByTestId('cancel-generation-btn').click();
    await expect.poll(server.cancels).toBe(2);
  }
  await expect(page.getByTestId('message-info')).toContainText('正在停止');
  server.result.resolve();
  await expect(page.getByTestId('preview-btn')).toBeDisabled();
  server.finish();
  server.creation.resolve();
  await expect(page.getByTestId('preview-btn')).toBeEnabled();
  await expect(page.getByTestId('text-input')).toHaveValue('取消测试，保留正文');
  await expect(page.getByTestId('preview-image')).toHaveCount(0);
  await expect.poll(()=>page.evaluate(()=>localStorage.getItem('studio.generation'))).toBeNull();
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  expect(server.count()).toBe(2);
 });
}

test('real backend stops a multipage render and accepts the next generation',async({page,request})=>{
 await openHome(page);await useSmallCanvas(page);
 let id;
 page.on('request',request=>{
   if(request.url().endsWith('/api/generate_handwriting'))id=request.headers()['x-panache-task-id'];
 });
 await page.getByTestId('text-input').fill(('真实停止测试，积分与矩阵。'.repeat(80)+'\n').repeat(80));
 await page.getByTestId('preview-btn').click();
 await page.getByTestId('cancel-generation-btn').click();
 await expect(page.getByTestId('preview-btn')).toBeEnabled();
 await expect.poll(()=>id).toBeTruthy();
 const stopped=await request.get(`/api/generate_handwriting/task/${id}`);
 expect((await stopped.json()).task_status).toBe('cancelled');
 await page.getByTestId('text-input').fill('停止后的新任务');
 await page.getByTestId('preview-btn').click();
 await expectPreviewImageLoaded(page);
});

test('lost submission response still cancels the preallocated server task', async ({page}) => {
 let id, cancelled;
 await page.routeWebSocket('**/api/generate_handwriting/ws/**', socket=>socket.close());
 await page.route('**/api/generate_handwriting', async route=>{
   id=route.request().headers()['x-panache-task-id'];
   await route.abort();
 });
 await page.route('**/api/generate_handwriting/task/**/cancel', async route=>{
   cancelled=route.request().url().split('/').at(-2);
   await route.fulfill({json:{task_id:cancelled,task_status:'cancelled'}});
 });
 await openHome(page); await useSmallCanvas(page);
 await page.getByTestId('text-input').fill('响应丢失，原文仍保留');
 await page.getByTestId('preview-btn').click();
 await expect.poll(()=>cancelled).toBeTruthy();
 expect(cancelled).toBe(id);
 await expect(page.getByTestId('message-info')).toContainText(/网络|Network/i);
 await expect(page.getByTestId('preview-btn')).toBeEnabled();
 await expect(page.getByTestId('text-input')).toHaveValue('响应丢失，原文仍保留');
 await expect.poll(()=>page.evaluate(()=>localStorage.getItem('studio.generation'))).toBeNull();
});


test('cancel preserves the previous preview and retries stopping after reload',async({page})=>{
 const server=await transport(page,{initialComplete:true,failOnce:true});
 await openHome(page);await useSmallCanvas(page);
 await page.getByTestId('text-input').fill('原有预览');
 await page.getByTestId('preview-btn').click();
 await expectPreviewImageLoaded(page);
 const previous=await page.getByTestId('preview-image').getAttribute('src');
 await page.getByTestId('text-input').fill('不替换原有预览');
 await page.getByTestId('preview-btn').click();
 await page.getByTestId('cancel-generation-btn').click();
 await expect(page.getByTestId('message-info')).toContainText('尚未确认');
 await expect(page.getByTestId('preview-image')).toHaveAttribute('src',previous);
 await expect.poll(()=>page.evaluate(()=>JSON.parse(localStorage.getItem('studio.generation')).cancelling)).toBe(true);
 await page.screenshot({path:path.join(__dirname,'../../preview_outputs/generation-stop-retry.png'),fullPage:true});
 await page.reload();
 await expect.poll(server.cancels).toBe(2);
 await expect(page.getByTestId('message-info')).toContainText('正在停止');
 await expect(page.getByTestId('preview-btn')).toBeDisabled();
 server.finish();
 await expect(page.getByTestId('preview-btn')).toBeEnabled();
 await expect.poll(()=>page.evaluate(()=>localStorage.getItem('studio.generation'))).toBeNull();
 expect(server.resultCalls()).toBe(1);
});

for (const mode of ['polling failure', 'render deadline']) {
  test(`automatically stops backend after ${mode} and waits for confirmation`, async ({ page }) => {
    const stopped = deferred();
    let cancelling = false, polls = 0;
    if (mode === 'render deadline') {
      await page.addInitScript(() => {
        const original = window.setTimeout.bind(window);
        window.setTimeout = (callback, delay, ...args) => original(callback, delay === 300000 ? 1000 : delay, ...args);
      });
    }
    await page.routeWebSocket('**/api/generate_handwriting/ws/**', socket => socket.close());
    await page.route('**/api/generate_handwriting', route => route.fulfill({ json: { task_id: route.request().headers()['x-panache-task-id'] } }));
    await page.route('**/api/generate_handwriting/task/**', async route => {
      if (route.request().url().endsWith('/cancel')) {
        cancelling = true;
        await route.fulfill({ json: { task_status: 'cancelling' } });
        return;
      }
      polls++;
      if (cancelling) {
        await stopped.promise;
        await route.fulfill({ json: { task_status: 'cancelled' } });
      } else if (mode === 'polling failure') await route.abort();
      else await route.fulfill({ json: { task_status: 'processing' } });
    });
    await openHome(page); await useSmallCanvas(page);
    await page.getByTestId('text-input').fill('后台仍在工作，取消前不能再开始');
    await page.getByTestId('preview-btn').click();
    await expect.poll(() => cancelling).toBe(true);
    expect(polls).toBeGreaterThan(0);
    await expect(page.getByTestId('preview-btn')).toBeDisabled();
    await expect(page.getByTestId('message-info')).toContainText('正在停止');
    stopped.resolve();
    await expect(page.getByTestId('preview-btn')).toBeEnabled();
    await expect(page.getByTestId('message-info')).toContainText(mode === 'render deadline' ? /超时|timed out/i : /网络|Network/i);
    await expect(page.getByTestId('preview-image')).toHaveCount(0);
    await expect.poll(() => page.evaluate(() => localStorage.getItem('studio.generation'))).toBeNull();
  });
}

test('legacy server waits for its real task identity and never treats cancel 404 as success', async ({ page }) => {
  const created = deferred();
  let cancelId, permitCancel = false;
  await page.route('**/api/version', route => route.fulfill({ json: { version: 'legacy' } }));
  await page.route('**/api/generate_handwriting', async route => {
    await created.promise;
    await route.fulfill({ json: { task_id: 'legacy-real-task' } });
  });
  await page.route('**/api/generate_handwriting/task/**/cancel', async route => {
    cancelId = route.request().url().split('/').at(-2);
    await route.fulfill({ status: permitCancel ? 200 : 404, json: permitCancel ? { task_status: 'cancelled' } : { message: 'Unsupported endpoint' } });
  });
  await openHome(page); await useSmallCanvas(page);
  await page.getByTestId('text-input').fill('旧服务器不接受预分配任务编号');
  await page.getByTestId('preview-btn').click();
  await page.getByTestId('cancel-generation-btn').click();
  await expect(page.getByTestId('preview-btn')).toBeDisabled();
  expect(cancelId).toBeUndefined();
  created.resolve();
  await expect.poll(() => cancelId).toBe('legacy-real-task');
  await expect(page.getByTestId('message-info')).toContainText('尚未确认');
  await expect(page.getByTestId('preview-btn')).toBeDisabled();
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('studio.generation')).taskId)).toBe('legacy-real-task');
  permitCancel = true;
  await page.getByTestId('cancel-generation-btn').click();
  await expect(page.getByTestId('preview-btn')).toBeEnabled();
  await expect(page.getByTestId('preview-image')).toHaveCount(0);
});


test('legacy lost response never invents an identity or confirms cancellation', async ({ page }) => {
  let cancels = 0;
  await page.route('**/api/version', route => route.fulfill({ json: { version: 'legacy' } }));
  await page.route('**/api/generate_handwriting', route => route.abort());
  await page.route('**/api/generate_handwriting/task/**/cancel', route => {
    cancels++;
    return route.fulfill({ json: { task_status: 'cancelled' } });
  });
  await openHome(page); await useSmallCanvas(page);
  await page.getByTestId('text-input').fill('旧服务丢失响应，不能声称后台已停止');
  await page.getByTestId('preview-btn').click();
  await expect(page.getByTestId('message-info')).toContainText('尚未确认');
  await expect(page.getByTestId('preview-btn')).toBeDisabled();
  expect(cancels).toBe(0);
  await page.getByTestId('cancel-generation-btn').click();
  await expect(page.getByTestId('message-info')).toContainText('尚未确认');
  await expect(page.getByTestId('preview-btn')).toBeDisabled();
  expect(cancels).toBe(0);
  await expect(page.getByTestId('preview-image')).toHaveCount(0);
  await expect(page.getByTestId('text-input')).toHaveValue('旧服务丢失响应，不能声称后台已停止');
});


test('stop during capability lookup never submits a backend job', async ({ page }) => {
  await openHome(page); await useSmallCanvas(page);
  const version = deferred();
  let lookup = false, submissions = 0;
  await page.route('**/api/version', async route => {
    lookup = true;
    await version.promise;
    await route.fulfill({ json: { version: 'test', capabilities: { task_submission_id: true } } });
  });
  await page.route('**/api/generate_handwriting', async route => {
    submissions++;
    await route.abort();
  });
  await page.getByTestId('text-input').fill('还没有提交任务');
  await page.getByTestId('preview-btn').click();
  await expect.poll(() => lookup).toBe(true);
  await page.getByTestId('cancel-generation-btn').click();
  await expect(page.getByTestId('preview-btn')).toBeEnabled();
  await expect(page.getByTestId('message-info')).toContainText('已停止生成');
  version.resolve();
  expect(submissions).toBe(0);
});


for (const status of [404, 410]) {
  test(`restoring a missing task (${status}) clears stale state without cancelling an unknown job`, async ({ page }) => {
    let cancelRequests = 0;
    await page.addInitScript(() => {
      localStorage.setItem('studio.generation', JSON.stringify({ version: 1, taskId: 'expired-task', mode: 'preview' }));
    });
    await page.routeWebSocket('**/api/generate_handwriting/ws/**', socket => socket.close());
    await page.route('**/api/generate_handwriting/task/expired-task', route => route.fulfill({ status, json: { message: 'Task expired' } }));
    await page.route('**/api/generate_handwriting/task/**/cancel', route => {
      cancelRequests++;
      return route.fulfill({ status: 404, json: { message: 'No cancellation endpoint' } });
    });
    await openHome(page);
    await expect(page.getByTestId('message-info')).toContainText('Task expired');
    await expect(page.getByTestId('preview-btn')).toBeEnabled();
    await expect.poll(() => page.evaluate(() => localStorage.getItem('studio.generation'))).toBeNull();
    expect(cancelRequests).toBe(0);
  });
}
