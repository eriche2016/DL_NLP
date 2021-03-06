-------------------------------------------------------------------------
-- In this part of the assignment you will become more familiar with the
-- internal structure of torch modules and the torch documentation.
-- You must complete the definitions of updateOutput and updateGradInput
-- for a 1-d log-exponential pooling module as explained in the handout.
-- 
-- Refer to the torch.nn documentation of nn.TemporalMaxPooling for an
-- explanation of parameters kW and dW.
-- 
-- Refer to the torch.nn documentation overview for explanations of the 
-- structure of nn.Modules and what should be returned in self.output 
-- and self.gradInput.
-- 
-- Don't worry about trying to write code that runs on the GPU.
--
-- Your submission should run on Mercer and contain: 
-- a completed TEAMNAME_A3_skeleton.lua,
--
-- a script TEAMNAME_A3_baseline.lua that is just the provided A3_baseline.lua modified
-- to use your TemporalLogExpPooling module instead of nn.TemporalMaxPooling,
--
-- a saved trained model from TEAMNAME_A3_baseline.lua for which you have done some basic
-- hyperparameter tuning on the training data,
-- 
-- and a script TEAMNAME_A3_gradientcheck.lua that takes as input from stdin:
-- a float epsilon, an integer N, N strings, and N labels (integers 1-5)
-- and prints to stdout the ratios |(FD_epsilon_ijk - exact_ijk) / exact_ijk|
-- where exact_ijk is the backpropagated gradient for weight ijk for the given input
-- and FD_epsilon_ijk is the second-order finite difference of order epsilon
-- of weight ijk for the given input.
------------------------------------------------------------------------

local TemporalLogExpPooling, parent = torch.class('nn.TemporalLogExpPooling', 'nn.Module')

function TemporalLogExpPooling:__init(kW, dW, beta)
   parent.__init(self)

   self.kW = kW
   self.dW = dW
   self.beta = beta

   self.indices = torch.Tensor()
end

function TemporalLogExpPooling:updateOutput(input)
   -----------------------------------------------
   -- if the input tensor is 2D (nInputFrame x inputFrameSize)
   if input:dim() ==  2 then

      -- nOutputFrame
      nOutputFrame = (input:size(1) - self.kW)/self.dW + 1
      -- Output tensor
      output = torch.Tensor(nOutputFrame, input:size(2)):fill(0)
      -- perform log exponential pooling
      iter = 1 --to keep track of what frame we are updating in output
      for i=1,input:size(1),self.dW do
         -- will store the summation of the exponents
         s = torch.Tensor(1,input:size(2)):fill(0)
         -- calculate the summation of the exponents and store in s
         if (i+self.kW-1) <= input:size(1) then --if what the kernel envelopes is not outside the limit
            for j=1,i+self.kW-1 do
               -- create a copy of the input so we won't modify the input values
               copyt = torch.Tensor(input[{ {j},{} }]:size()):copy(input[{ {j},{} }])
               s:add(torch.exp(copyt:mul(self.beta)))
            end
            -- Divide by N
            s = s/self.kW
            -- log the summation of the exponents and multiply by inverse of beta
            s = torch.log(s)/self.beta
            -- copy to output
            output[{ {iter},{} }] = s
            iter = iter + 1
         end
      end

   -- if the input tensor is 3D (nBatchFrame x nInputFrame x inputFrameSize)
   else

      -- nOutputFrame
      nOutputFrame = (input:size(2) - self.kW)/self.dW + 1
      -- Output tensor
      output = torch.Tensor(input:size(1), nOutputFrame, input:size(3)):fill(0)
      -- perform log exponential pooling
      iter = 1 --to keep track of what frame we are updating in output
      for i=1,input:size(2),self.dW do
         -- will store the summation of the exponents
         s = torch.Tensor(input:size(1),1,input:size(3)):fill(0)
         -- calculate the summation of the exponents and store in s
         if (i+self.kW-1) <= input:size(2) then --if what the kernel envelopes is not outside the limit
            for j=1,i+self.kW-1 do
               -- create a copy of the input so we won't modify the input values
               copyt = torch.Tensor(input[{ {},{j},{} }]:size()):copy(input[{ {},{j},{} }])
               s:add(torch.exp(copyt:mul(self.beta)))
            end
            -- Divide by N
            s = s/self.kW
            -- log the summation of the exponents and multiply by inverse of beta
            s = torch.log(s)/self.beta
            -- copy to output
            output[{ {}, {iter}, {} }] = s
            iter = iter + 1
         end
      end

   end

   self.output = torch.Tensor(output:size()):copy(output)
   -----------------------------------------------
   return self.output
end

function TemporalLogExpPooling:updateGradInput(input, gradOutput)
   -----------------------------------------------
   -- if the input tensor is 2D (nInputFrame x inputFrameSize)
   if input:dim() ==  2 then

      gradInput = torch.Tensor(input:size()):fill(0)
      
      -- calc a tensor that holds the sum of exp(beta*xj) for each column
      temp_vals = torch.Tensor(input:size()):copy(input)
      temp_vals = torch.exp( temp_vals * self.beta )
      sum_exp_beta = torch.Tensor(1,temp_vals:size(2)):fill(0)
      for i=1,temp_vals:size(2) do sum_exp_beta[{ {},{i} }] = temp_vals[{ {},{i} }]:sum() end

      -- counter for using gradOutput
      iter = 1
      -- calculate gradInput by dividing each xk by the sum_exp_beta and multiplying by coresponding gradient
      for i=1,input:size(1),self.dW do
         if (i+self.kW-1) <= input:size(1) then
         grad = torch.Tensor(input[{ {i,i+self.kW-1},{} }]:size()):copy(input[{ {i,i+self.kW-1},{} }])
         grad = torch.exp( grad * self.beta )
            for j=1,self.kW do
               -- divide by sum of exp beta
               grad[{ {j},{} }]:cdiv(sum_exp_beta)
               --multiply by corresponding gradient
               grad[{ {j},{} }]:cmul(gradOutput[{ {iter},{} }])
            end
         gradInput[{ {i,i+self.kW-1},{} }] = grad[{ {j},{} }]
         end
      iter = iter + 1
      end

   -- if the input tensor is 3D (nBatchFrame x nInputFrame x inputFrameSize)
   else

      gradInput = torch.Tensor(input:size()):fill(0)
      
      -- calc a tensor that holds the sum of exp(beta*xj) for each column
      temp_vals = torch.Tensor(input:size()):copy(input)
      temp_vals = torch.exp( temp_vals * self.beta )
      sum_exp_beta = torch.Tensor(temp_vals:size(1),1,temp_vals:size(3)):fill(0)
      for i=1,temp_vals:size(3) do sum_exp_beta[{ {},{},{i} }] = temp_vals[{ {},{},{i} }]:sum() end

      -- counter for using gradOutput
      iter = 1
      -- calculate gradInput by dividing each xk by the sum_exp_beta and multiplying by coresponding gradient
      for i=1,input:size(2),self.dW do
         if (i+self.kW-1) <= input:size(2) then
            grad = torch.Tensor(input[{ {},{i,i+self.kW-1},{} }]:size()):copy(input[{ {},{i,i+self.kW-1},{} }])
            grad = torch.exp( grad * self.beta )
            for j=1,self.kW do
               -- divide by sum of exp beta
               grad[{ {},{j},{} }]:cdiv(sum_exp_beta)
               --multiply by corresponding gradient
               grad[{ {},{j},{} }]:cmul(gradOutput[{ {},{iter},{} }])
            end
         gradInput[{ {},{i,i+self.kW-1},{} }] = grad[{ {},{j},{} }]
         end
      iter = iter + 1
      end

   end
   -----------------------------------------------
   self.gradInput = torch.Tensor(gradInput:size()):copy(gradInput)
   return self.gradInput
end

function TemporalLogExpPooling:empty()
   self.gradInput:resize()
   self.gradInput:storage():resize(0)
   self.output:resize()
   self.output:storage():resize(0)
   self.indices:resize()
   self.indices:storage():resize(0)
end