-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
gdsGui_generateConsoleMessage ("info", "Unit testing initialized")

local _suites = {}

function gdsGui_unitTests_registerSuite(name, fn)
	table.insert(_suites, {name = name, fn = fn})
end

function gdsGui_unitTests_reset()
	for i = #devTests, 1, -1 do
		table.remove(devTests, i)
	end
end

function gdsGui_unitTests_rerunAll()
	gdsGui_unitTests_reset()
	gdsGui_unitTests_executeAll()
end

function gdsGui_unitTests_executeAll(strPageName)
	for _, suite in ipairs(_suites) do
		suite.fn()
	end
	gdsGui_dev_writeTestResults ("console", "fail")
end

gdsGui_unitTests_registerSuite("gui", function()

	--------------------------------------------------------------------------
							--LIB_GENERAL.LUA
	--------------------------------------------------------------------------
		gdsGui_dev_testExecute {["id"]="gdsGui_general_determineSafeArea(android,landscape)_test",
						["funcName"]={"gdsGui_general_determineSafeArea"},
						["funcParameters"]={"landscape", "iOS", 1000, 500 ,true},
						["funcExpctOutput"]={60, 0, 880, 470}}

		gdsGui_dev_testExecute {["id"]="gdsGui_general_determineSafeArea(ios,portrait)_test",
						["funcName"]={"gdsGui_general_determineSafeArea"},
						["funcParameters"]={"portrait", "Android", 1000, 500 ,true},
						["funcExpctOutput"]={0, 30, 1000, 440}}

		gdsGui_dev_testExecute {["id"]="gdsGui_general_determineSafeArea(windows,landscape)_test",
						["funcName"]={"gdsGui_general_determineSafeArea"},
						["funcParameters"]={"landscape", "Windows", 1000, 500 ,true},
						["funcExpctOutput"]={0, 0, 1000, 500}}

		gdsGui_dev_testExecute {["id"]="gdsGui_general_isTouchInSafeArea(wrongYtouch)_test",
						["funcName"]={"gdsGui_general_isTouchInSafeArea"},
						["funcParameters"]={1,-1},
						["funcExpctOutput"]={false}}

		gdsGui_dev_testExecute {["id"]="gdsGui_general_isTouchInSafeArea(correct)_test",
						["funcName"]={"gdsGui_general_isTouchInSafeArea"},
						["funcParameters"]={globApp.safeScreenArea.x+ 1 ,globApp.safeScreenArea.y + 1},
						["funcExpctOutput"]={true}}

		gdsGui_dev_testExecute {["id"]="relativePosition_test",
						["funcName"]={"gdsGui_general_relativePosition"},
						["funcParameters"]={"CC", .5, .85, 100, 100, 0, 0, 200, 200},
						["funcExpctOutput"]={50,120}}

		gdsGui_dev_testExecute {["id"]="jpGUI_convertSafeAreaPercentToDPI_test_pass500",
						["funcName"]={"gdsGui_general_convertSafeAreaToDPI"},
						["funcParameters"]={.5,"width",true},
						["funcExpctOutput"]={500}}

		gdsGui_dev_testExecute {["id"]="jpGUI_convertSafeAreaPercentToDPI_test_pass400",
						["funcName"]={"gdsGui_general_convertSafeAreaToDPI"},
						["funcParameters"]={.4,"height",true},
						["funcExpctOutput"]={400}}

		gdsGui_dev_testExecute {["id"]="jpGUI_convertSafeAreaPercentToDPI_test_passError",
						["funcName"]={"gdsGui_general_convertSafeAreaToDPI"},
						["funcParameters"]={.4,"height6",nil},
						["funcExpctOutput"]={"error"}}

		gdsGui_dev_testExecute {["id"]="isTextRemoveCommanded_false",
						["funcName"]={"gdsGui_general_isTextRemoveCommanded"},
						["funcParameters"]={"c"},
						["funcExpctOutput"]={false}}

		gdsGui_dev_testExecute {["id"]="isTextRemoveCommanded_trueBackspace",
						["funcName"]={"gdsGui_general_isTextRemoveCommanded"},
						["funcParameters"]={"backspace"},
						["funcExpctOutput"]={true}}

		gdsGui_dev_testExecute {["id"]="isTextRemoveCommanded_trueDelete",
						["funcName"]={"gdsGui_general_isTextRemoveCommanded"},
						["funcParameters"]={"delete"},
						["funcExpctOutput"]={true}}

		gdsGui_dev_testExecute {["id"]="findScreenOrientation_test",
						["funcName"]={"gdsGui_general_findScreenOrientation"},
						["funcParameters"]={800, 1000, true},
						["funcExpctOutput"]={"portrait"}}


	----------------------------------------------------------------------------
								--PAGES
	----------------------------------------------------------------------------

		gdsGui_dev_testExecute {["id"]="isPgActive_(xp:false)test",
						["funcName"]={"gdsGui_page_isActive"},
						["funcParameters"]={999},
						["funcExpctOutput"]={false}}

		gdsGui_dev_testExecute {["id"]="isPgActive_(xp:true)test",
						["funcName"]={"gdsGui_page_isActive"},
						["funcParameters"]={globApp.currentPageIndex},
						["funcExpctOutput"]={true}}

		-- Save original current page index
		local originalPageIndex = globApp.currentPageIndex
		-- Temporarily set current page index to DeveloperMenu for testing
		globApp.currentPageIndex = 20050
		gdsGui_dev_testExecute {["id"]="returnCurrentPageName_test",
						["funcName"]={"gdsGui_page_currentName"},
						["funcParameters"]={globApp.currentPageIndex},
						["funcExpctOutput"]={"DeveloperMenu"}}
		-- Restore original current page index
		globApp.currentPageIndex = originalPageIndex

		gdsGui_dev_testExecute {["id"]="doesPageExist_test_true",
						["funcName"]={"gdsGui_page_doesExist"},
						["funcParameters"]={1},
						["funcExpctOutput"]={true}}

		gdsGui_dev_testExecute {["id"]="doesPageExist_test_false",
						["funcName"]={"gdsGui_page_doesExist"},
						["funcParameters"]={1000987},
						["funcExpctOutput"]={false}}




		-- Table with an intentionally invalid entry at [1] for invalid-ID tests,
		-- plus 999 valid GDS-format entries generated by the ID function.
		local testSavedProjectTable = {[1]= {["ID"] = "INVALID_FORMAT"}}
		local testRecIDlocator = "TST"
		for i=2, 1000, 1 do
			testSavedProjectTable [i]= {["ID"] = gdsGui_saveLoad_createIdNumber (testSavedProjectTable, testRecIDlocator, 7)}
		end

		-- Separate small table with only valid GDS IDs for the count-mismatch test.
		local testValidTable = {[1] = {["ID"] = gdsGui_saveLoad_createIdNumber ({}, testRecIDlocator, 7)}}
		gdsGui_dev_testExecute {["id"]="createNewProjectData_noMatchCount",
						["funcName"]={"gdsGui_saveLoad_createProjectData"},
						["funcParameters"]={{15,true,"hello"},{"asldkf", 5}, testValidTable, "TST", 7},
						["funcExpctOutput"]={"The data labels and data pieces count do NOT match, ref createNew ProjectData funciton and callbacks"}}

		gdsGui_dev_testExecute {["id"]="doesSerialNumExistsInTable_true",
						["funcName"]={"gdsGui_saveLoad_doesSerialExist"},
						["funcParameters"]={testSavedProjectTable,"INVALID_FORMAT"},
						["funcExpctOutput"]={true}}

		gdsGui_dev_testExecute {["id"]="doesSerialNumExistsInTable_false",
						["funcName"]={"gdsGui_saveLoad_doesSerialExist"},
						["funcParameters"]={testSavedProjectTable,"GDS99999999999999999"},
						["funcExpctOutput"]={false}}

		gdsGui_dev_testExecute {["id"]="doesTableHaveInvalidRecordsIDs_trueRecIDNotFound",
						["funcName"]={"gdsGui_saveLoad_hasInvalidIDs"},
						["funcParameters"]={testSavedProjectTable,"NIL", 20},
						["funcExpctOutput"]={true}}

		gdsGui_dev_testExecute {["id"]="doesTableHaveInvalidRecordsIDs_trueDueToOneInvalRecID",
						["funcName"]={"gdsGui_saveLoad_hasInvalidIDs"},
						["funcParameters"]={testSavedProjectTable,testRecIDlocator, 20},
						["funcExpctOutput"]={true}}

		table.remove(testSavedProjectTable, 1)

		gdsGui_dev_testExecute {["id"]="doesTableHaveInvalidRecordsIDs_false",
						["funcName"]={"gdsGui_saveLoad_hasInvalidIDs"},
						["funcParameters"]={testSavedProjectTable,testRecIDlocator, 20},
						["funcExpctOutput"]={false}}


		gdsGui_dev_testExecute {["id"]="isTableEmpty_false",
						["funcName"]={"gdsGui_saveLoad_isTableEmpty"},
						["funcParameters"]={testSavedProjectTable},
						["funcExpctOutput"]={false}}


		local testTable = {}
			testTable[2] = {1, 2, 3}
			testTable[3] = {"yes", 1, true, 0.56}
			testTable[4] = {"no", 1, true, 0.56}

		gdsGui_dev_testExecute {["id"]="areTwoTablesSameSize_false",
						["funcName"]={"gdsGui_saveLoad_areSameSize"},
						["funcParameters"]={testTable[2],testTable[3]},
						["funcExpctOutput"]={false}}

		gdsGui_dev_testExecute {["id"]="areTwoTablesSameSize_true",
						["funcName"]={"gdsGui_saveLoad_areSameSize"},
						["funcParameters"]={testTable[3],testTable[4]},
						["funcExpctOutput"]={true}}

		testTable = nil
		testSavedProjectTable [50]= nil
		gdsGui_dev_testExecute {["id"]="areThereNILvalues_trueOneValueNil",
						["funcName"]={"gdsGui_saveLoad_hasNilValues"},
						["funcParameters"]={testSavedProjectTable},
						["funcExpctOutput"]={true}}

		testSavedProjectTable [50]= "new"
		gdsGui_dev_testExecute {["id"]="areThereNILvalues_false",
						["funcName"]={"gdsGui_saveLoad_hasNilValues"},
						["funcParameters"]={testSavedProjectTable},
						["funcExpctOutput"]={false}}

		testSavedProjectTable = {}
		gdsGui_dev_testExecute {["id"]="isTableEmpty_true",
						["funcName"]={"gdsGui_saveLoad_isTableEmpty"},
						["funcParameters"]={testSavedProjectTable},
						["funcExpctOutput"]={true}}
		testSavedProjectTable = nil

		local testSavedProjectTable2 = {[1]= {	["ID"] = "GDS12345678901234567",
												["data"] = {},
												["boolean"]= true,
												["number"] = 6,
												["string"] = "_trg_"} }

		local testRecIDlocator2 = "DEV"

		for i=2, 10, 1 do
			testSavedProjectTable2 [i]= {["ID"] = gdsGui_saveLoad_createIdNumber (testSavedProjectTable2, testRecIDlocator2,7)}
		end

		gdsGui_dev_testExecute {["id"]="findTableIndexByRecordID_rtrn1",
						["funcName"]={"gdsGui_saveLoad_findIndexByID"},
						["funcParameters"]={testSavedProjectTable2, testRecIDlocator2, "GDS12345678901234567", 20},
						["funcExpctOutput"]={1}}

		gdsGui_dev_testExecute {["id"]="findTableIndexByRecordID_IDNot found",
						["funcName"]={"gdsGui_saveLoad_findIndexByID"},
						["funcParameters"]={testSavedProjectTable2, testRecIDlocator2, "GDS99999999999999999", 20},
						["funcExpctOutput"]={"Could Not Find the provided record ID"}}

		testSavedProjectTable2 [11]= {["ID"] = "INVALID_ID_FORMAT"}
		gdsGui_dev_testExecute {["id"]="findTableIndexByRecordID_tableIssue",
						["funcName"]={"gdsGui_saveLoad_findIndexByID"},
						["funcParameters"]={testSavedProjectTable2, testRecIDlocator2, "GDS99999999999999999", 20},
						["funcExpctOutput"]={"there is an issue with the provided table"}}


		local testFont = love.graphics.newFont(1)

		local testTextTable = {}
				testTextTable[1] = "sometext"
				testTextTable[2] = "1234567810123456782012345678301234567840123456785012345678601234567870"
				testTextTable[3] = "some textsome text, more text"

		gdsGui_dev_testExecute {["id"]="findMaxNumOfLinesNeeded_rtr5",
						["funcName"]={"findMaxNumOfLinesNeeded"},
						["funcParameters"]={testFont, 10, testTextTable},
						["funcExpctOutput"]={7}}

		gdsGui_dev_testExecute {["id"]="gdsGui_general_returnFontInfo",
						["funcName"]={"gdsGui_general_returnFontInfo"},
						["funcParameters"]={testFont, "lineHeight"},
						["funcExpctOutput"]={1}}

		-- ABOUT FILE CONTENTS AND EXISTENCE

		local tempTestFile001_content = "testy2 test"

		local tempTestFile001 = love.filesystem.newFile("tempTestFile001.txt")

		tempTestFile001:open("w")

		gdsGui_dev_testExecute {["id"]="doesAboutPageFileExistFalse",
						["funcName"]={"gdsGui_general_doesAboutPageExist"},
						["funcParameters"]={"tempTestFile002.txt", true},
						["funcExpctOutput"]={false}}

		gdsGui_dev_testExecute {["id"]="doesAboutPageFileExistTrue",
						["funcName"]={"gdsGui_general_doesAboutPageExist"},
						["funcParameters"]={"tempTestFile001.txt", true},
						["funcExpctOutput"]={true}}

		gdsGui_dev_testExecute {["id"]="isAboutTextFileEmptyTrue",
						["funcName"]={"gdsGui_general_isAboutFileEmpty"},
						["funcParameters"]={"tempTestFile001.txt", true},
						["funcExpctOutput"]={true}}

		tempTestFile001:write(tempTestFile001_content)

		gdsGui_dev_testExecute {["id"]="isAboutTextFileEmptyFalse",
						["funcName"]={"gdsGui_general_isAboutFileEmpty"},
						["funcParameters"]={"tempTestFile001.txt", true},
						["funcExpctOutput"]={false}}

		tempTestFile001:close()

		love.filesystem.remove( "tempTestFile001.txt" )


		-----------------------------------------------------------------------------------
										--INPUT TEXT BOX FUNCTION
		-----------------------------------------------------------------------------------

		gdsGui_dev_testExecute {["id"]="inputTextBox_isNewCharInvalid_true",
						["funcName"]={"gdsGui_inputTxtBox_isCharInvalid"},
						["funcParameters"]={1, {["pattern"]="%l", ["maxCharCount"]=1,["invalCharacters"]={"/"}}, 0, ""},
						["funcExpctOutput"]={true}}
-- newCharacter, tblTextSpecs, currentChrCount, currentText


		gdsGui_dev_testExecute {["id"]="gdsGui_general_isTouchInSafeArea(correct)_test",
						["funcName"]={"gdsGui_general_isTouchInSafeArea"},
						["funcParameters"]={globApp.safeScreenArea.x + 1 ,globApp.safeScreenArea.y + 1},
						["funcExpctOutput"]={true}}

end)
