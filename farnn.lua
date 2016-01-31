--[[Source Code that implements the algorithm described in the paper:
   A Fully Automated Recurrent Neural Network for System Identification and Control
   Jeen-Shing Wang, and Yen-Ping Chen. IEEE Transactions on Circuits and Systems June 2006

   Author: Olalekan Ogunmolu, SeRViCE Lab, UT Dallas, December 2015
   MIT License
   ]]

-- needed dependencies
require 'torch'
require 'nn'
matio   = require 'matio'       

--[[modified native Torch Linear class to allow random weight initializations
 and avoid local minima issues ]]
do
    local Linear, parent = torch.class('nn.CustomLinear', 'nn.Linear')    
    -- override the constructor to have the additional range of initialization
    function Linear:__init(inputSize, outputSize, mean, std)
        parent.__init(self,inputSize,outputSize)                
        self:reset(mean,std)
    end    
    -- override the :reset method to use custom weight initialization.        
    function Linear:reset(mean,stdv)        
        if mean and stdv then
            self.weight:normal(mean,stdv)
            self.bias:normal(mean,stdv)
        else
            self.weight:normal(0,1)
            self.bias:normal(0,1)
        end
    end
end

-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('========================================================================')
cmd:text('A Fully Automated Dynamic Neural Network for System Identification')
cmd:text('Based on the IEEE Transactions on Circuits and Systems article by ')
cmd:text()
cmd:text('           Jeen-Shing Wang, and Yen-Ping Chen. June 2006          ')
cmd:text()
cmd:text()
cmd:text('Code by Olalekan Ogunmolu: FirstName [dot] LastName _at_ utdallas [dot] edu')
cmd:text('========================================================================')
cmd:text()
cmd:text()
cmd:text('Options')
cmd:option('-seed', 123, 'initial random seed to use')
cmd:option('-rundir', false, 'log output to file in a directory? Default is false')

-- Model Order Determination Parameters
cmd:option('-pose','posemat7.mat','path to preprocessed data(save in Matlab -v7.3 format)')
cmd:option('-tau', 1, 'what is the delay in the data?')
cmd:option('-quots', 0, 'do you want to print the Lipschitz quotients?; 0 to silence, 1 to print')
cmd:option('-m_eps', 0.01, 'stopping criterion for output order determination')
cmd:option('-l_eps', 0.05, 'stopping criterion for input order determination')
cmd:option('-trainStop', 0.5, 'stopping criterion for input order determination')
cmd:option('-sigma', 0.01, 'initialize weights with this std. dev from a normally distributed Gaussian distribution')

--Gpu settings
cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU; >=0 use gpu')
cmd:option('-backend', 'cudnn', 'nn|cudnn')

-- Neural Network settings
cmd:option('-learningRate', 0.0055, 'learning rate for the neural network')
cmd:option('-maxIter', 1000, 'maximum iteration for training the neural network')

--parse input params
params = cmd:parse(arg)


-- misc
local opt = cmd:parse(arg)
torch.manualSeed(opt.seed)

-- create log file if user specifies true for rundir
if(opt.rundir==true) then
	params.rundir = cmd:string('experiment', params, {dir=false})
	paths.mkdir(params.rundir)
	cmd:log(params.rundir .. '/log', params)
end

cmd:addTime('FARNN Identification', '%F %T')
cmd:text('Code initiated on CPU')
cmd:text()
cmd:text()


-------------------------------------------------------------------------------
-- Basic Torch initializations
-------------------------------------------------------------------------------
--torch.setdefaulttensortype('torch.FloatTensor')            -- for CPU
if opt.gpuid >= 0 then
  require 'cutorch'
  require 'cunn'
  if opt.backend == 'cudnn' then require 'cudnn' end
  cutorch.manualSeed(opt.seed)
  cutorch.setDevice(opt.gpuid + 1)                         -- +1 because lua is 1-indexed
  idx 			= cutorch.getDevice()
  print('System has', cutorch.getDeviceCount(), 'gpu(s).', 'Code is running on GPU:', idx)
  data    		= opt.pose       --ship raw data to gpu
else 
	data 		= opt.pose
end

----------------------------------------------------------------------------------------
-- Parsing Raw Data
----------------------------------------------------------------------------------------
input      = matio.load(data, 'in')						--SIMO System
-- print('\ninput head\n\n', input[{ {1,5}, {1}} ])
trans     = matio.load(data, {'xn', 'yn', 'zn'})
roll      = matio.load(data, {'rolln'})
pitch     = matio.load(data, {'pitchn'})
yaw       = matio.load(data, {'yawn'})
rot       = {roll, pitch, yaw}


out        = matio.load(data, 'zn')
out        = out/10;							--because zn was erroneosly multipled by 10 in the LabVIEW Code.
print('\nSISO output head\n\n', out[{ {1,5}, {1}} ])

u 		   = input[{ {}, {1}}]
y 		   = out  [{ {}, {1}}]

local   k  = u:size()[1]
off  = torch.ceil( torch.abs(0.6*k))
dataset    = {input, out}
u_off      = input[{{1, off}, {1}}]     --offline data
y_off      = out  [{{1, off}, {1}}]

u_on       = input[{{off + 1, k}, {1}}]	--online data
y_on       = out  [{{off + 1, k}, {1}}]


--[[Determine input-output order using He and Asada's prerogative
    See Code order_det.lua in folder "order"]]

orderdet = require 'order.order_det'

--find optimal # of input variables from data
qn  = order_det.computeqn(u_off, y_off)
print('\nqn:' , qn)
print('Optimal number of input variables is: ', torch.ceil(qn))

--compute actual system order
utils = require 'order.utils'
inorder, outorder, q =  order_det.computeq(u_off, y_off, opt)
print('inorder: ', inorder, 'outorder: ', outorder)
print('system order:', inorder + outorder)

--Print out some Lipschitz quotients (first 5) for user
if opt.quots == 1 then
	for k, v in pairs( q ) do
		print(k, v)
		if k == 5 then      
			break
		end
	end
end


--[[Set up the network, add layers in place as we add more abstraction]]
local neunet        = nn.Sequential()
input = 1 	 output = 1 	HUs = 1;
print('neunet1 biases Linear', neunet.bias)
neunet:add(nn.ReLU())                       	
--neunet.modules[1].weights = torch.rand(input, HUs):mul(opt.sigma)
neunet:add(nn.Linear(HUs, output))				
--create a deep copy of neunet for NLL training
neunet2 = neunet:clone('weight', bias);
print('\nneunet_1 biases\n', neunet:get(1).bias, '\tneunet_1 weights: ', neunet:get(1).weights)

--[[ Function to evaluate loss and gradient.
-- optim.lbfgs internally handles iteration and calls this fucntion many
-- times]]
local num_calls = 0
local function feval(x)
  num_calls = num_calls + 1
  net:forward(x)
  local grad = net:backward(x, dy)
  local loss = 0
  for _, mod in ipairs(content_losses) do
    loss = loss + mod.loss
  end
  for _, mod in ipairs(style_losses) do
    loss = loss + mod.loss
  end
  maybe_print(num_calls, loss)
  maybe_save(num_calls)

  collectgarbage()
  -- optim.lbfgs expects a vector for gradients
  return loss, grad:view(grad:nElement())
end

-- Run optimization.
if opt.optimizer == 'lbfgs' then
  print('Running optimization with L-BFGS')
  local x, losses = optim.lbfgs(feval, img, optim_state)
end

--Training using the MSE criterion
function msetrain(neunet, x, y, learningRate)
	i = 0
	repeat
		local input = x
		local output = y
		criterion = nn.MSECriterion()           -- Loss function
		trainer   = nn.StochasticGradient(neunet, criterion)
		learningRate = 0.5 --
		learningRateDecay = 0.0055
		trainer.maxIteration = opt.maxIter
		--Forward Pass
		 err = criterion:forward(neunet2:forward(input), output)
		i = i + 1
		print('MSE_iter', i, 'MSE error: ', err)
		  neunet2:zeroGradParameters()
		  neunet2:backward(input, criterion:backward(neunet2.output, output))		  neunet2:updateParameters(learningRate, learningRateDecay)
	until err <= opt.trainStop    --stopping criterion for MSE based optimization
return i, err
end

i, mse_error = msetrain(neunet2, u_off, y_off, learningRate)
print('MSE iteration', i, 'MSE error: ', mse_error, '\n')

 print('neunet gradient weights', neunet.gradWeight)
 print('neunet gradient biases', neunet.gradBias)

--Test Network (MSE)
-- x = u_on
-- print('=========================================================')
-- print('       Example results head post-training using MSE      ')
-- print(              neunet:forward(x)[{ {1, 5}, {} }]               )
-- print('                        Error: ', err                     )
-- print('=========================================================')                


--Train using the Negative Log Likelihood Criterion
function gradUpdate(neunet, x, y, learningRate)	
   iN = 0
   local NLLcriterion 	= nn.ClassNLLCriterion()
   local pred 	  		= neunet:forward(x)
   NLLerr 		= criterion:forward(pred, y)
   iN = iN + 1
   print('NLL_iter', iN, 'NLL error: ', NLLerr)
   neunet:zeroGradParameters()
   local t          = criterion:backward(pred, y)
   neunet:backward(x, t)
   neunet:updateParameters(opt.learningRate)
   return iN, NLLerr
end


local inNLL = u_off 	local outNLL = y_off

repeat
	iNLL, delta = gradUpdate(neunet, inNLL, outNLL, opt.learningRate)
	--print('NLL_iter', iNLL, 'NLL error: ', delta)
until delta < opt.trainStop    --stopping criterion for backward pass
--[[
for i, module in ipairs(neunet:listModules()) do
	print('neunet1 Modules are: \n', module)
end
--]]