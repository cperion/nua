-- The same task/channel/pool algorithms run with copied native step functions.
package.loaded['nua.driver_loaded'] = true
arg = {[0]='nua.lua'}
local nua = dofile('nua.lua')
local ffi = require 'ffi'
local baseline = nua.load('examples/channels.nua')
local execute,popen = os.execute,io.popen
os.execute = function() error('direct task compilation started a process',0) end
io.popen = os.execute
local ok,actual = pcall(nua.load,'examples/channels.nua',{backend='direct'})
os.execute,io.popen = execute,popen
assert(ok,actual)
local c=require('tests.direct_support').c_baseline(nua,'examples/channels.nua',actual,'c-channels')
local checks=0
local function same(name,...)
    local expected=baseline[name](...)
    assert(c[name](...)==expected,'C task result: '..name)
    assert(actual[name](...)==expected,'task result: '..name)
    assert(actual.raw[name](...)==expected,'native task result: '..name)
    checks=checks+3
end
same('sum_squares',1000)
same('sum_squares',0)
same('total_steps4',50)
same('merged',40)
same('ask',30)
same('tally',20,7)
same('nested',3,8)
same('grow_in_task',1000)
same('pooled',40)
same('poll_empty')
same('gives_up')
same('late_reply')
same('take_or_time')
same('parallel_sleeps',4)
baseline=nua.load('examples/io.nua')
os.execute=function() error('direct I/O compilation started a process',0) end
io.popen=os.execute
ok,actual=pcall(nua.load,'examples/io.nua',{backend='direct'})
os.execute,io.popen=execute,popen
assert(ok,actual)
c=require('tests.direct_support').c_baseline(nua,'examples/io.nua',actual,'c-io')
same('pipe_roundtrip')
local path='build/direct/io-data.bin'
same('file_roundtrip',ffi.new('char[?]',#path+1,path))
same('timeout_then_data')
same('echo',3)
same('zero_copy',20)
same('refused')
assert(actual.pipe_roundtrip()==12 and actual.timeout_then_data()==31)
assert(actual.echo(3)==3 and actual.zero_copy(20)==320 and actual.refused())
print(('direct tasks/I/O: %d scheduler/channel/pool/timer/blocking/I/O comparisons passed'):format(checks))
