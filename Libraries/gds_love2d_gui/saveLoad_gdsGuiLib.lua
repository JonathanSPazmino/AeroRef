-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[saveLoad.lua
	contains all code necessary to manage project data. save and load
	it uses open source software show.lua referenced below]]


function gdsGui_saveLoad_createProjectData ( arrDataLabels, arrData, dataTable, recordIDLocator, numIDRandomDigit)

   --[[takes a specially formated data table, checks if data labels and pieces
      count matched, checks if serial number exits, processes the data, organizes 
      data, creates timeStamps and a unique ID, and returns the same table for 
      further use]]
   local labelsCount = 0
   local dataPiecesCount = 0
   local recordIDLength = 20  -- GDS + 17 digits = 20 chars


   local isThereNilLabels = gdsGui_saveLoad_hasNilValues (arrDataLabels)
   local isThereNilDataPieces = gdsGui_saveLoad_hasNilValues (arrData)
   local isSameNumOfLabelsAndData = gdsGui_saveLoad_areSameSize (arrDataLabels, arrData)
   local gdsGui_saveLoad_isTableEmpty = gdsGui_saveLoad_isTableEmpty (dataTable)


   local doesTableContainInvalidRecords = gdsGui_saveLoad_hasInvalidIDs (dataTable, recordIDLocator, recordIDLength)

   if gdsGui_saveLoad_isTableEmpty == true or  (isSameNumOfLabelsAndData == true and doesTableContainInvalidRecords == false and isThereNilLabels == false and isThereNilDataPieces == false) then
      
      local newProjectData = {}
      local timestamp = string.sub(os.time(), 8, 11)

   	newProjectData["dateCreated"] = os.date("%Y/%m/%d")
      newProjectData["data"] = {}
      newProjectData["ID"] = gdsGui_saveLoad_createIdNumber (dataTable, recordIDLocator, numIDRandomDigit)

      for i=1, #arrDataLabels, 1 do
         newProjectData[arrDataLabels[i]] = arrData [i]
      end 

      return newProjectData
   else

      local errorMessage = "The data labels and data pieces count do NOT match, ref createNew ProjectData funciton and callbacks"

      return errorMessage
   end
end

function gdsGui_saveLoad_findIndexByID (searchT, recordIDLocator,recordId, idLength)
   --[[returns numerical index representing a table record index number]]
   local gdsGui_saveLoad_isTableEmpty = gdsGui_saveLoad_isTableEmpty (searchT)
   local doesTableContainInvalidRecords = gdsGui_saveLoad_hasInvalidIDs (searchT, recordIDLocator, idLength)
   local isThereNilIndex = gdsGui_saveLoad_hasNilValues (searchT)

   local indexMatch = false

   if gdsGui_saveLoad_isTableEmpty == false and doesTableContainInvalidRecords == false and isThereNilIndex == false then
      local foundRecord = {}
      for i=1, #searchT, 1 do
         if searchT[i]["ID"] == recordId then
            indexMatch = true
            return i
         end
      end
      if indexMatch==false then
         local notFoundMsg = "Could Not Find the provided record ID"
         return notFoundMsg
      end
   else 
      local prvdedTableIssue = "there is an issue with the provided table"
      return prvdedTableIssue
   end
end 

function gdsGui_saveLoad_getDataByIndex (t, indexNum, rtrnType)
   -- rtrnType Table or info 
   local tblResult = {}

   for i, prjt in ipairs (t) do
      if i == indexNum then

         tblResult = prjt
         if rtrnType == "info" then
            local strgResult = ""
            for j, data in pairs (tblResult) do

               if type (data) == "table" or type (data) == "boolean" then
                  strgResult = (strgResult .. j .. "=" .. type(data) .. "|")
               else
                  strgResult = (strgResult .. j .. "=" .. data  .. "|")
               end
               
            end
            return strgResult
         elseif rtrnType == "table" then
            return tblResult
         end
         
      end
   end
end

function gdsGui_saveLoad_hasNilValues (tableOrVariable)
   --[[ returns true if NIL values are found in table or variable]]
   local result = true 

   --checks if parameter if nil
   if tableOrVariable == nil then 
      return result
   else
      local parmtrType = type(tableOrVariable)
      if parmtrType == "table" then
         for i=1, #tableOrVariable, 1 do
            if tableOrVariable[i] == nil then
               return result
            end
         end
      end 
      result = false
      return   result
   end
end

function gdsGui_saveLoad_areSameSize (table1, table2)
   --[[ INFO: compares the number of variables in a single dimension array

      INPUT:
      table1: ------------Table--------------single dimensionErray
      table2: ------------Table--------------single dimensionErray

      OUTPUT:
      result--------------Boolean-------------representing equality btw 2 tables
   ]]

   local result = false

   if #table1 == #table2 then
      result = true
   end

   return result
end

function gdsGui_saveLoad_hasInvalidIDs (table, recordIDLocator, idLength)

   --[[ INFO: compares the number of variables in a single dimension array

      INPUT:
      table: ------------Table--------------table to be examined for valid records
      recordIDLocator ---STRING-------------THREE LETTER CODE, AVOID NIL, TST, NOR

      OUTPUT:
      result--------------Boolean-------------representing whether valid recs found
   ]]

   local result = false
   local invalidID = false

   for i, thisProject in ipairs (table) do

      for j, thisID in pairs (thisProject) do

         if j == "ID" then
            local s = thisID
            -- validate GDS format: GDS + 17 digits = 20 chars
            if not string.match(s, "^GDS%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
               invalidID = true
            end
         end

      end

   end

   if invalidID == true then

      result = true

   end

   return result
end

function gdsGui_saveLoad_createIdNumber (recordsTable, recordIDLocator, numRandomDigits)

   --[[ INFO: creates a unique 10-character ID in the format GDS#####AZ
         where ##### is 5 random digits (00000-99999).
         Checks for duplicates and regenerates until unique.

         FORMAT:  GDS  +  17 digits  =  20 characters
         EXAMPLE: GDS73941028563719402

         INPUT:
         recordsTable: -----------Table--------------special formatted table
         recordIDLocator:---------String--------------field name holding the ID
         numRandomDigits:---------Number--------------reserved, fixed at 5

         OUTPUT:
         result-------------------String-------------10-char GDS ID
      ]]

   local result
   local iterate = true
   local numIteration = 0

   while iterate == true do

      iterate = false

      local digits = ""
      for i = 1, 17 do
         digits = digits .. math.random(0, 9)
      end
      local newSerialNumber = "GDS" .. digits

      local doesRecordExist = gdsGui_saveLoad_doesSerialExist(recordsTable, newSerialNumber)

      if doesRecordExist == true then
         numIteration = numIteration + 1
         iterate = true
         print("New ID was remade " .. numIteration .. "x due to collision")
      else
         result = newSerialNumber
      end

   end

   return result
end

function gdsGui_saveLoad_isTableEmpty (table)

   local result = false

   if #table == 0 then

      result = true

   end

   return result
end

function gdsGui_saveLoad_doesSerialExist (table, projectID)

   --[[ INFO: returns true or false depending if project id exits in
         provided table

      INPUT:
      recordTable: ------------Table--------------special formated table
      table={[1]={["ID" = ID ]}}

      OUTPUT:
      result--------------------boolean-----------if SN is found false else true

   ]]

   local result = false
   local savedProjects = table

   for i, project in ipairs (savedProjects) do

         
      for j, data in pairs (project)do
          -- print (project)
          --   print (projectID)
         if data == projectID then
            result = true

         end
      end
   end

   return result
end

function gdsGui_saveLoad_sortProjectsTable()

  local sortedTable = {}

  for i, tbls in pairs (globApp.projects) do

    table.insert (sortedTable, i)

  end

  table.sort (sortedTable)

  for i = 1, #sortedTable, 1 do

    for j, tbls in pairs (globApp.projects) do

      if j == i then

        sortedTable[i] = tbls

      end

    end 

  end

  globApp.projects = sortedTable
end

function gdsGui_saveLoad_sortDataTable (parTable)
   local preSortingData = parTable
   local sortedIndexes = {}
   --creates a table with indexes based on preSortingData table count
   for i=1, #parTable,1 do
      table.insert (sortedIndexes, i)
   end
   -- table.sort (sortedIndexes)

   local sortedTable = {}
   for i = 1, #sortedIndexes, 1 do
      for j, tbls in ipairs (preSortingData) do
         if j == i then
            sortedTable[i] = tbls
         end
      end 
   end

   return sortedTable
end

function gdsGui_saveLoad_saveProject (fileName, Data, SavingTag)
  --[[called from main.lua create new project button]]
	--[[fileName --------------string --------------------name of dataSavingFile
		Data-------------------Multiple-------------------any data type, preferebly table
		SavingTag--------------String---------------------name of variable or table for 												  lua code retrieval execution]]
	
  love.filesystem.write(fileName, table.show(Data, SavingTag))
end

function gdsGui_saveLoad_loadFileContents (strFileName)
   --[[checks if file exists]]
	if love.filesystem.getInfo (strFileName) then 
      --[[assigns function that loads data contained in file to variable]]
		local loadData = love.filesystem.load(strFileName) 
      --[[calls the function which loads it data back to the globApp.projects table]]
		loadData() 
	end
end

function gdsGui_saveLoad_updateProjectAvailability ()

  local availability = false

   if #globApp.projects >= 1 then

      availability = true

  end 

	globApp.projectAvailable = availability
end

function gdsGui_saveLoad_deleteProject (t, projectID)
   -- convert id to index number
   local deletingIndex = ""
   for i, prjt in ipairs (globApp.projects) do
      if projectID == prjt.ID then 
         -- print ("index= " .. i .. " / " .. prjt.ID .. " found ")
         deletingIndex = i
      end
   end
   -- delete converted index number
   for j = #t,1,-1 do
      if j == deletingIndex then
         -- print ("deleting index = " .. j)
         table.remove(t,j)
         globApp.projectsTblChanged = true
      end
   end
   gdsGui_saveLoad_saveProject ("savedProjectData.lua", globApp.projects, "globApp.projects")
end

function gdsGui_saveLoad_overwriteProjectData (id, dataLabel, newValue)

   for i, prjt in ipairs (globApp.projects) do
      if id == prjt.ID then 
         -- print ("before " .. prjt[dataLabel])
         prjt[dataLabel] = newValue

         -- print ("index= " .. i .. " / " .. prjt.ID .. " found /" .. prjt[dataLabel]) 

         gdsGui_saveLoad_sortProjectsTable()

         gdsGui_saveLoad_saveProject ("savedProjectData.lua", globApp.projects, "globApp.projects")

         globApp.projectsTblChanged = true

      end
   end

end

-- GDS Lua table serializer — original implementation by Gateway Dynamic Software, LLC
-- Converts a Lua table to valid Lua source that can be reloaded with love.filesystem.load().
-- Handles nested tables, cycles, all primitive types, and function references.
function table.show(tbl, varName, baseIndent)
    varName    = varName    or "__unnamed__"
    baseIndent = baseIndent or ""

    local function encodeValue(v)
        local vt = type(v)
        if vt == "number" or vt == "boolean" then
            return tostring(v)
        elseif vt == "function" then
            local di = debug.getinfo(v, "S")
            if di.what == "C" then
                return string.format("%q", tostring(v) .. ", C function")
            end
            return string.format("%q", tostring(v) ..
                ", defined in (" .. di.linedefined ..
                "-" .. di.lastlinedefined .. ")" .. di.source)
        else
            return string.format("%q", tostring(v))
        end
    end

    if type(tbl) ~= "table" then
        return varName .. " = " .. encodeValue(tbl)
    end

    local chunks   = {}
    local deferred = {}
    local visited  = {}

    local function walk(node, path, pad, labelExpr)
        table.insert(chunks, pad .. labelExpr)

        if type(node) ~= "table" then
            chunks[#chunks] = chunks[#chunks] .. " = " .. encodeValue(node) .. ";\n"
            return
        end

        if visited[node] then
            chunks[#chunks] = chunks[#chunks] ..
                " = {}; -- " .. visited[node] .. " (self reference)\n"
            table.insert(deferred, path .. " = " .. visited[node] .. ";\n")
            return
        end

        visited[node] = path

        if next(node) == nil then
            chunks[#chunks] = chunks[#chunks] .. " = {};\n"
        else
            chunks[#chunks] = chunks[#chunks] .. " = {\n"
            for k, v in pairs(node) do
                local ek    = encodeValue(k)
                local child = string.format("%s[%s]", path, ek)
                local lbl   = string.format("[%s]", ek)
                walk(v, child, pad .. "   ", lbl)
            end
            table.insert(chunks, pad .. "};\n")
        end
    end

    walk(tbl, varName, baseIndent, varName)
    for _, s in ipairs(deferred) do table.insert(chunks, s) end
    return table.concat(chunks)
end

--loads all available project data from file system files see lib
 gdsGui_saveLoad_loadFileContents ("savedProjectData.lua") 