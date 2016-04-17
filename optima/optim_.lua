--[[ Run optimization: User has three options:
We could train usin the genral mean squared error, Limited- Broyden-Fletcher-GoldFarb and Shanno or the
Negative Log Likelihood Function ]]
require 'torch'
optim_ = {}
--Training using the MSE criterion
function msetrain(neunet, cost, x, y, opt, data)
 
  --https://github.com/torch/nn/blob/master/doc/containers.md#Parallel

  --reset grads
  gradParameters:zero()

  local fm = 0     local pred = {}     local errm = {}  local x_fwd = {}
  local gradcrit = {}   local error_acc = {}   local y_fwd = {}--torch.Tensor(1,6)

  for j_mse                 = 1, data[1]:size()[1] do
       pred                 = neunet:forward(x)
        --dirty hack to retrieve elements of target vectors
       y_fwd               = torch.cat({y[1], y[2], y[3], y[4], y[5], y[6]})
       --calculate errors
        errm                = cost:forward(pred, y_fwd)
        --show what you got
        fm                  = errm + fm
        table.insert(error_acc, errm)
        --print('==>Printing errors in each minibatch of ', opt.batchSize)
        learningRate = opt.learningRate
        --[[if fm > 150 then learningRate = opt.learningRate
        elseif fm <= 150 then learningRate = opt.learningRateDecay end]]

        gradcrit         = cost:backward(pred, y_fwd)

        --https://github.com/torch/nn/blob/master/doc/module.md
        neunet:zeroGradParameters();
        neunet:backward(x, gradcrit)
        neunet:updateParameters(learningRate);

        -- normalize gradients and f(X)
        gradParameters:div(data[1]:size()[1])
        fm = fm/(data[1]:size()[1])
  end

  return gradParameters, fm, errm, error_acc
end

collectgarbage()

--Train using the L-BFGS Algorithm
function lbfgs(neunet, x, y, learningRate) 
   local trainer        = nn.StochasticGradient(neunet2, cost)
   trainer.learningRate = learningRate
   trainer:train({x, y})
   return neunet2
end

collectgarbage()                           --yeah, sure. come in and argue :)

--[[--create closure to evaluate f(x): https://github.com/torch/tutorials/blob/master/2_supervised/4_train.lua
    local feval = function(x)
                    collectgarbage()

                    --retrieve new params
                    if x~=parameters then
                      parameters:copy(x)
                    end

                    --reset grads
                    gradParameters:zero()
          
                    -- f is the average of all criterions
                    local f = 0

                    -- evaluate function for complete mini batch
                    for i_f = 1,#inputs do
                        print('#inputs', #inputs)
                        -- estimate f
                        local output = neunet:forward(inputs[i_f])
                        local err = cost:forward(output, targets[i_f])
                        f = f + err
                        print('feval error', err)

                        -- estimate df/dW
                        local df_do = cost:backward(output, targets[i_f])
                        neunet:backward(inputs[i_f], df_do)

                        -- penalties (L1 and L2):
                        if opt.coefL1 ~= 0 or opt.coefL2 ~= 0 then
                           -- locals:
                           local norm,sign= torch.norm,torch.sign

                           -- Loss:
                           f = f + opt.coefL1 * norm(parameters,1)
                           f = f + opt.coefL2 * norm(parameters,2)^2/2

                           -- Gradients:
                           gradParameters:add( sign(parameters):mul(opt.coefL1) + parameters:clone():mul(opt.coefL2) )
                        
                        else
                          -- normalize gradients and f(X)
                          gradParameters:div(#inputs)
                        end

                        -- update confusion
                        --confusion:add(output, targets[i_f])
                    end

                    -- normalize gradients and f(X)
                    gradParameters:div(#inputs)
                    f = f/#inputs

                    --retrun f and df/dx
                    return f, gradParameters
                  end]]

--Other optimizer
--[[]]                  