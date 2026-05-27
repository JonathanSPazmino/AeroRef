--timeControl.lua

timeTriggerObjetcs = {}

function gdsGui_timeControl_createTrigger (myName, myIntervals, myCalledFunctions)
	--[[
		NOTES: calls functions at interval times

		INPUT: 
			myName
			myType


	]]

	local newTimeTrigger = {}

	local countIntervals = 0
	for i = 1 , #myIntervals, 1 do
		countIntervals = countIntervals + 1 
	end

	local countCalledFunctions = 0
	for i =1, #myCalledFunctions, 1 do
		countCalledFunctions = countCalledFunctions + 1
	end

	newTimeTrigger.name = myName
	newTimeTrigger.running = true
	
	newTimeTrigger.startTime = 0
	newTimeTrigger.endTime = 0
	newTimeTrigger.intervals = {}
	for i=1, #myIntervals, 1 do
		newTimeTrigger.intervals[i] = myIntervals[i]
		if myIntervals[i] >= newTimeTrigger.endTime then
		newTimeTrigger.endTime = myIntervals[i]
		end
	end

	newTimeTrigger.intervalFunctionCalls = {}
	for i=1, #myCalledFunctions, 1 do
		newTimeTrigger.intervalFunctionCalls[i] = myCalledFunctions[i]
	end

	newTimeTrigger.currentTime = 0

	table.insert (timeTriggerObjetcs, newTimeTrigger)

end


function gdsGui_timeControl_updateTrigger (dt)

	local runningTimeTriggers = 0

	for i, t in ipairs (timeTriggerObjetcs) do
		
		if t.running == true and t.currentTime <= t.endTime then
			runningTimeTriggers = i
			t.currentTime = t.currentTime + dt
		elseif t.running ==true and t.currentTime > t.endTime then
			t.currentTime = 0
			t.running = false
			gdsGui_timeControl_deleteTrigger (t.name)
		end

		local intFuncDiff = #t.intervals - #t.intervalFunctionCalls

		
		if intFuncDiff == 0 then

			for j, intv in ipairs(t.intervals) do
		
				if t.currentTime >= intv and t.intervalFunctionCalls[j] ~= 0 then

					getfenv()[t.intervalFunctionCalls[j]]()

					-- print (t.name .. "/"..t.intervalFunctionCalls[j] .. " ... At " .. t.currentTime  .. " was executed!")

					t.intervalFunctionCalls[j] = 0

				end

			end

		elseif intFuncDiff > 0 then

			for j, intv in ipairs(t.intervals) do

				if j > intFuncDiff then

					if t.currentTime >= intv and t.intervalFunctionCalls[j-1] ~= 0 then

						getfenv()[t.intervalFunctionCalls[j-1]]()

						-- print (t.name .. "/"..t.intervalFunctionCalls[j - 1] .. " ... At " .. t.currentTime .. " ".. " was executed!/" .. " intCount :".. #t.intervals .. "/j: " .. j)

						t.intervalFunctionCalls[j - 1] = 0

					end

				end

			end

		elseif intFuncDiff < 0 then

			for j, intv in ipairs(t.intervals) do

				for j, intv in ipairs(t.intervals) do
		
					if t.currentTime >= intv and t.intervalFunctionCalls[j] ~= 0 then

						if j == #t.intervals then

							for k=j, #t.intervalFunctionCalls, 1 do

								getfenv()[t.intervalFunctionCalls[k]]()

								-- print (t.name .. "/"..t.intervalFunctionCalls[k] .. " ... At " .. t.currentTime  .. " was executed!")

								t.intervalFunctionCalls[k] = 0

							end

						elseif j~= #t.intervals then
							
							getfenv()[t.intervalFunctionCalls[j]]()

							-- print (t.name .. "/"..t.intervalFunctionCalls[j] .. " ... At " .. t.currentTime  .. " was executed!")
							
							t.intervalFunctionCalls[j] = 0
						
						end

					end

				end

			end

		end
			
	end

end


function gdsGui_timeControl_deleteTrigger (myName)

	for i = #timeTriggerObjetcs,1,-1 do

		local timer = timeTriggerObjetcs[i]

		if timer.name == myName then

			table.remove(timeTriggerObjetcs,i)

		end

	end

end


function gdsGui_timeControl_testTrigger ()

	if not globApp.developerMode then return end

	for i, t in ipairs (timeTriggerObjetcs) do

		love.graphics.print(math.ceil(t.currentTime), 50, (i*30) + 50, r, sx, sy, ox, oy, kx, ky)

		local timerIndex = ("Timer index: " .. #timeTriggerObjetcs )

		love.graphics.print(timerIndex, 70, 80, r, sx, sy, ox, oy, kx, ky)

	end

end