require 'torch'
require 'nn'
require 'optim'
require 'string'
require 'xlua'
require 'cunn'

ffi = require('ffi')

-- set seed for recreating tests
torch.manualSeed(1)

--- Parses and loads the GloVe word vectors into a hash table:
-- glove_table['word'] = vector
function load_glove(path, inputDim)
    
    local glove_file = io.open(path)
    local glove_table = {}

    local line = glove_file:read("*l")
    while line do
        -- read the GloVe text file one line at a time, break at EOF
        local i = 1
        local word = ""
        for entry in line:gmatch("%S+") do -- split the line at each space
            if i == 1 then
                -- word comes first in each line, so grab it and create new table entry
                word = entry:gsub("%p+", ""):lower() -- remove all punctuation and change to lower case
                if string.len(word) > 0 then
                    glove_table[word] = torch.zeros(inputDim, 1) -- padded with an extra dimension for convolution
                else
                    break
                end
            else
                -- read off and store each word vector element
                glove_table[word][i-1] = tonumber(entry)
            end
            i = i+1
        end
        line = glove_file:read("*l")
    end
    
    return glove_table
end

-- function to read in raw document data and convert to quantized vectors
function preprocess_data(raw_data, wordvector_table, opt)
    
    -- create empty tensors that will hold wordvector concatenations
    local data = torch.zeros(opt.nClasses*(opt.nTrainDocs+opt.nTestDocs), opt.length, opt.inputDim)
    local labels = torch.zeros(opt.nClasses*(opt.nTrainDocs + opt.nTestDocs))
    
    -- use torch.randperm to shuffle the data, since it's ordered by class in the file
    local order = torch.randperm(opt.nClasses*(opt.nTrainDocs+opt.nTestDocs))
    
    for i=1,opt.nClasses do
        for j=1,opt.nTrainDocs+opt.nTestDocs do
            local k = order[(i-1)*(opt.nTrainDocs+opt.nTestDocs) + j]
            
            local index = raw_data.index[i][j]
            -- standardize to all lowercase
            local document = ffi.string(torch.data(raw_data.content:narrow(1, index, 1))):lower()
            local wordcount = 1
            -- break each review into words and concatenate into a vector thats of size length x inputDim
            for word in document:gmatch("%S+") do
                if wordcount < opt.length then
                    if wordvector_table[word:gsub("%p+", "")] then
                        data[{ {k},{wordcount},{} }] = wordvector_table[word:gsub("%p+", "")]
                        wordcount = wordcount + 1
                    end
                end
            end

            labels[k] = i
        end
    end

    return data, labels
end


function train_model(model, criterion, training_data, training_labels, opt)

	-- classes
	classes = {'1','2','3','4','5'}

	-- This matrix records the current confusion across classes
	confusion = optim.ConfusionMatrix(classes)

    parameters,gradParameters = model:getParameters()

    -- configure optimizer
    optimState = {
    	learningRate = opt.learningRate,
    	weightDecay = opt.weightDecay,
    	momentum = opt.momentum,
    	learningRateDecay = opt.learningRateDecay
    }
    optimMethod = optim.sgd

    epoch = epoch or 1
	local time = sys.clock()

	model:training()

	inputs = torch.zeros(opt.batchSize,opt.length,opt.inputDim):cuda()
	targets = torch.zeros(opt.batchSize):cuda()

	-- do one epoch
	print("\n==> online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')
	for t = 1,training_data:size(1),opt.batchSize do
		-- disp progress
		-- xlua.progress(t, training_data:size(1))
		inputs:zero()
		targets:zero()

		-- create mini batch
		if t + opt.batchSize-1 <= training_data:size(1) then
			-- xx = opt.batchSize
			inputs[{}] = training_data[{ {t,t+opt.batchSize-1},{},{} }]
			targets[{}] = training_labels[{ {t,t+opt.batchSize-1} }]
		
			-- create closure to evaluate f(X) and df/dX
			local feval = function(x)
				-- get new parameters
				if x ~= parameters then
					parameters:copy(x)
				end
				-- reset gradients
				gradParameters:zero()
				-- f is the average of all criterions
				local f = 0
				-- evaluate function for complete mini batch
				-- estimate f
				local output = model:forward(inputs)
				local err = criterion:forward(output, targets)
				f = f + err
				-- estimate df/dW
				local df_do = criterion:backward(output, targets)
				model:backward(inputs, df_do)
				-- update confusion
				for k=1,opt.batchSize do
					confusion:add(output[k], targets[k])
				end
				-- return f and df/dX
				return f,gradParameters
			end

			-- optimize on current mini-batch
			optimMethod(feval, parameters, optimState)
		end
	end

	-- time taken
	time = sys.clock() - time
	time = time / training_data:size(1)
	print("==> time to learn 1 sample = " .. (time*1000) .. 'ms')

	-- print confusion matrix
	-- print(confusion)
	confusion:updateValids()

	-- print accuracy
	print("==> training accuracy for epoch " .. epoch .. ':')
	print(confusion.totalValid*100)

	-- save/log current net
	local filename = paths.concat(opt.save, 'model.net')
	os.execute('mkdir -p ' .. sys.dirname(filename))
	print('==> saving model to '..filename)
	torch.save(filename, model)

	-- next epoch
	confusion:zero()
	epoch = epoch + 1

end

function test_model(model, data, labels, opt)

    model:evaluate()

    t_input = torch.zeros(opt.length, opt.inputDim):cuda()
    t_labels = torch.zeros(1):cuda()
    -- test over test data
    for t = 1,data:size(1) do
        t_input:zero()
        t_labels:zero()
        t_input[{}] = data[t]
        t_labels[{}] = labels[t]
        local pred = model:forward(t_input)
        confusion:add(pred, t_labels[1])
    end
    -- print(confusion)
    confusion:updateValids()

    -- print accuracy
    print("==> test accuracy for epoch " .. epoch .. ':')
    -- print(confusion)
    print(confusion.totalValid*100)
    confusion:zero()
end


function main()

    -- Configuration parameters
    opt = {}
    -- word vector dimensionality
    opt.inputDim = 200
    -- paths to glovee vectors and raw data
    opt.glovePath = "/home/eduardo/A3/glove/glove.6B." .. opt.inputDim .. "d.txt"
    opt.dataPath = "/home/eduardo/A3/data/train.t7b"
    -- path to save model to
    opt.save = "results"
    -- maximum number of words per text document
    opt.length = 100
    -- training/test sizes
    opt.nTrainDocs = 15000
    opt.nTestDocs = 1000
    opt.nClasses = 5

    -- training parameters
    opt.nEpochs = 20
    opt.batchSize = 128
    opt.learningRate = 0.1
    opt.learningRateDecay = 1e-5
    opt.momentum = 0.9
    opt.weightDecay = 0

    print("Loading word vectors...")
    local glove_table = load_glove(opt.glovePath, opt.inputDim)
    
    print("Loading raw data...")
    raw_data = torch.load(opt.dataPath)
    
    print("Computing document input representations...")
    processed_data, labels = preprocess_data(raw_data, glove_table, opt)

    print("Splitting data into training and validation sets...")
    -- split data into makeshift training and validation sets
    training_data = processed_data[{ {1,opt.nClasses*opt.nTrainDocs},{},{} }]:clone()
    training_labels = labels[{ {1,opt.nClasses*opt.nTrainDocs} }]:clone()
   
    if opt.nTestDocs > 0 then
        test_data = processed_data[{ {(opt.nClasses*opt.nTrainDocs)+1,opt.nClasses*(opt.nTrainDocs+opt.nTestDocs)},{},{} }]:clone()
        test_labels = labels[{ {(opt.nClasses*opt.nTrainDocs)+1,opt.nClasses*(opt.nTrainDocs+opt.nTestDocs)} }]:clone()
    else
        test_data = training_data:clone()
        test_labels = training_labels:clone()
    end

    -- build model *****************************************************************************
    model = nn.Sequential()
    -- first layer (#alphabet x 100)
    model:add(nn.TemporalConvolution(opt.inputDim, 256, 5))
    model:add(nn.Threshold())
    model:add(nn.TemporalMaxPooling(2,2))

    -- second layer (48x256) 48 = (100 - 5 / 1 + 1) / 2
    -- model:add(nn.TemporalConvolution(256, 256, 5))
    -- model:add(nn.Threshold())
    -- model:add(nn.TemporalMaxPooling(2,2))

    -- 1st fully connected layer (22x256) 22 = (48 - 5 / 1 + 1) / 2
    model:add(nn.Reshape(48*256))
    model:add(nn.Linear(48*256,1024))
    model:add(nn.Threshold())
    model:add(nn.Dropout(0.5))

    -- 2nd fully connected layer (1024)
    -- model:add(nn.Linear(1024,1024))
    -- model:add(nn.Threshold())
    -- model:add(nn.Dropout(0.5))

    -- final layer for classification
    model:add(nn.Linear(1024,5))
    model:add(nn.LogSoftMax())

	criterion = nn.ClassNLLCriterion()

	-- CUDA
	model:cuda()
	criterion:cuda()

	print("\nTraining model...")
    for i=1,opt.nEpochs do
		train_model(model, criterion, training_data, training_labels, opt)
        test_model(model,test_data,test_labels,opt)
	end
    -- local results = test_model(model, test_data, test_labels)
    -- print(results)
end

main()