/**
 * Presenter 上传接收端（Google Apps Script 网页应用）
 *
 * 用法（详见 README“上传记录到 Google Drive”）：
 *   1. script.google.com 新建项目，把这个文件的内容贴进 Code.gs
 *   2. 项目设置 › 脚本属性：FOLDER_ID = 上传文件夹 ID；TOKEN = 暗号（openssl rand -hex 24）
 *   3. 部署 › 新建部署 › 网页应用：执行身份“我”，谁可以访问“任何人”；网址填进 config-local.json 的 upload.url
 *
 * Presenter 发来 JSON {token, folder, name, data(base64)}，存成 FOLDER_ID/folder/name；同名旧文件放进回收站。
 * 只能往这个文件夹里写：不能读，也不能删别的东西。换暗号 = 改脚本属性 TOKEN，旧暗号立刻失效。
 */
function doPost(e) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
    var props = PropertiesService.getScriptProperties();
    var req = JSON.parse(e.postData.contents);
    if (!req.token || req.token !== props.getProperty('TOKEN')) return reply({ ok: false, error: 'bad token' });
    var name = clean(req.name);
    if (!name || typeof req.data !== 'string') return reply({ ok: false, error: 'bad request' });
    var folder = DriveApp.getFolderById(props.getProperty('FOLDER_ID'));
    if (req.folder) folder = subfolder(folder, clean(req.folder));
    var blob = Utilities.newBlob(Utilities.base64Decode(req.data), 'text/plain', name);
    var old = folder.getFilesByName(name);
    while (old.hasNext()) old.next().setTrashed(true);   // 只留最新的一份
    var file = folder.createFile(blob);
    return reply({ ok: true, id: file.getId(), bytes: blob.getBytes().length });
  } catch (err) {
    return reply({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function subfolder(parent, name) {
  var it = parent.getFoldersByName(name);
  return it.hasNext() ? it.next() : parent.createFolder(name);
}

function clean(s) {
  return String(s || '').replace(/[\/\\:\u0000-\u001f]/g, '_').slice(0, 200);
}

function reply(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
