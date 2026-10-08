-- Original bounded message transport. BeamMP packets stay small even for damage data.
local M={chunkSize=12000,maxBytes=12*1024*1024}
local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local values={};for i=1,#alphabet do values[alphabet:sub(i,i)]=i-1 end
function M.decode64(s)
  if type(s)~='string' or s:find('[^A-Za-z0-9+/_=]') then return nil end
  s=s:gsub('_','Z')
  local out={}
  for i=1,#s,4 do
    local a,b,c,d=s:sub(i,i),s:sub(i+1,i+1),s:sub(i+2,i+2),s:sub(i+3,i+3)
    if not values[a] or not values[b] then return nil end
    local n=values[a]*262144+values[b]*4096+(values[c] or 0)*64+(values[d] or 0)
    out[#out+1]=string.char(math.floor(n/65536)%256)
    if c~='=' and c~='' then out[#out+1]=string.char(math.floor(n/256)%256) end
    if d~='=' and d~='' then out[#out+1]=string.char(n%256) end
  end
  return table.concat(out)
end
function M.encode64(s)
  local out={}
  for i=1,#s,3 do
    local a,b,c=s:byte(i,i+2);local n=a*65536+(b or 0)*256+(c or 0)
    out[#out+1]=alphabet:sub(math.floor(n/262144)%64+1,math.floor(n/262144)%64+1)
    out[#out+1]=alphabet:sub(math.floor(n/4096)%64+1,math.floor(n/4096)%64+1)
    out[#out+1]=b and alphabet:sub(math.floor(n/64)%64+1,math.floor(n/64)%64+1) or '='
    out[#out+1]=c and alphabet:sub(n%64+1,n%64+1) or '='
  end
  -- Launcher 2.8.1 aborts for a large packet containing "Zp" anywhere in its
  -- body (ServerSend, GlobalHandler.cpp). Keep Z out of encoded payloads.
  return (table.concat(out):gsub('Z','_'))
end
function M.accept(jobs,key,p,now)
  if type(p)~='table' or type(p.id)~='string' or #p.id>100 or
    type(p.total)~='number' or p.total%1~=0 or p.total<1 or p.total>M.maxBytes*4/3+4 or
    type(p.offset)~='number' or p.offset%1~=0 or type(p.chunk)~='string' or #p.chunk>M.chunkSize or
    p.chunk:find('[^A-Za-z0-9+/_=]') then return nil end
  local job=jobs[key]
  if not job then
    if p.offset~=1 then return nil end
    job={parts={},length=0,total=p.total,at=now};jobs[key]=job
  end
  if job.total~=p.total then jobs[key]=nil;return nil end
  if p.offset==job.length+1 then job.parts[#job.parts+1]=p.chunk;job.length=job.length+#p.chunk end
  if job.length>job.total then jobs[key]=nil;return nil end
  if job.length==job.total then jobs[key]=nil;return M.decode64(table.concat(job.parts)) end
end
return M
