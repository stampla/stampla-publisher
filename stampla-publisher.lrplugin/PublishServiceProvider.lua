local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrErrors = import "LrErrors"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrView = import "LrView"

local bind = LrView.bind

local provider = {}

provider.supportsIncrementalPublish = "only"
provider.canExportVideo = true
provider.hideSections = { "exportLocation", "fileNaming" }

provider.exportPresetFields = {
	{ key = "publishRoot", default = "" },
	{ key = "folderLayout", default = "collections" },
	{ key = "sourceRoot", default = "" },
	{ key = "filenameSuffix", default = "_lr" },
	{ key = "onRemove", default = "trash" },
}

function provider.updateExportSettings(exportSettings)
	exportSettings.LR_export_destinationType = "tempFolder"
	exportSettings.LR_renamingTokensOn = false
end

function provider.sectionsForTopOfDialog(f, propertyTable)
	return {
		{
			title = "Publish destination",
			synopsis = bind "publishRoot",

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = "Publish root:",
					alignment = "right",
					width = LrView.share "stampla_label",
				},
				f:edit_field {
					value = bind "publishRoot",
					fill_horizontal = 1,
				},
				f:push_button {
					title = "Browse…",
					action = function()
						local chosen = LrDialogs.runOpenPanel {
							title = "Choose publish root",
							canChooseFiles = false,
							canChooseDirectories = true,
							canCreateDirectories = true,
							allowsMultipleSelection = false,
						}
						if chosen and chosen[1] then
							propertyTable.publishRoot = chosen[1]
						end
					end,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = "Folder layout:",
					alignment = "right",
					width = LrView.share "stampla_label",
				},
				f:popup_menu {
					value = bind "folderLayout",
					items = {
						{ title = "Collection sets and collections as folders", value = "collections" },
						{ title = "Mirror the masters' folder tree", value = "mirror" },
					},
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = "Source root:",
					alignment = "right",
					width = LrView.share "stampla_label",
				},
				f:edit_field {
					value = bind "sourceRoot",
					fill_horizontal = 1,
					enabled = LrBinding.keyEquals("folderLayout", "mirror"),
				},
				f:push_button {
					title = "Browse…",
					enabled = LrBinding.keyEquals("folderLayout", "mirror"),
					action = function()
						local chosen = LrDialogs.runOpenPanel {
							title = "Choose source root",
							canChooseFiles = false,
							canChooseDirectories = true,
							canCreateDirectories = false,
							allowsMultipleSelection = false,
						}
						if chosen and chosen[1] then
							propertyTable.sourceRoot = chosen[1]
						end
					end,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = "Filename suffix:",
					alignment = "right",
					width = LrView.share "stampla_label",
				},
				f:edit_field {
					value = bind "filenameSuffix",
					immediate = true,
					width_in_chars = 8,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = "When removed:",
					alignment = "right",
					width = LrView.share "stampla_label",
				},
				f:popup_menu {
					value = bind "onRemove",
					items = {
						{ title = "Move published file to trash", value = "trash" },
						{ title = "Delete published file", value = "delete" },
						{ title = "Leave published file in place", value = "leave" },
					},
				},
			},
		},
	}
end

-- Path of `path` relative to `root`: "" if equal, nil if outside.
local function relativeTo(root, path)
	local last = root:sub(-1)
	if last == "/" or last == "\\" then
		root = root:sub(1, -2)
	end
	if path == root then
		return ""
	end
	local boundary = path:sub(#root + 1, #root + 1)
	if path:sub(1, #root) == root and (boundary == "/" or boundary == "\\") then
		return path:sub(#root + 2)
	end
	return nil
end

local function applyOnRemove(mode, path)
	if mode == "leave" or LrFileUtils.exists(path) ~= "file" then
		return
	end
	if mode == "delete" then
		LrFileUtils.delete(path)
	else
		LrFileUtils.moveToTrash(path)
	end
end

function provider.processRenderedPhotos(_, exportContext)
	local settings = exportContext.propertyTable
	local collectionInfo = exportContext.publishedCollectionInfo
	local collectionName = collectionInfo.name

	local root = settings.publishRoot
	if not root or root == "" then
		LrErrors.throwUserError("Set a publish root in the publish service settings.")
	end
	if LrFileUtils.exists(root) ~= "directory" then
		LrErrors.throwUserError("Publish root does not exist: " .. root)
	end

	local layout = settings.folderLayout or "collections"
	local sourceRoot = settings.sourceRoot
	local collectionDir

	if layout == "mirror" then
		if not sourceRoot or sourceRoot == "" then
			LrErrors.throwUserError("Set a source root in the publish service settings"
				.. " to mirror the masters' folder tree.")
		end
		if LrFileUtils.exists(sourceRoot) ~= "directory" then
			LrErrors.throwUserError("Source root does not exist: " .. sourceRoot)
		end
	else
		-- Collection sets nest into subfolders: the target folder is the
		-- publish root joined with each ancestor set's name, then the
		-- collection's own name.
		collectionDir = root
		for _, parent in ipairs(collectionInfo.parents or {}) do
			collectionDir = LrPathUtils.child(collectionDir, parent.name)
		end
		collectionDir = LrPathUtils.child(collectionDir, collectionName)
	end

	local nRenditions = exportContext.exportSession:countRenditions()
	exportContext:configureProgress {
		title = string.format("Publishing %d file%s to %s",
			nRenditions, nRenditions == 1 and "" or "s", collectionName),
	}

	local claimed = {}

	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		local ok, rendered = rendition:waitForRender()
		if ok then
			local targetDir = collectionDir
			if layout == "mirror" then
				local masterFolder = LrPathUtils.parent(
					rendition.photo:getRawMetadata("path"))
				local rel = relativeTo(sourceRoot, masterFolder)
				if rel == nil then
					targetDir = nil
					LrFileUtils.delete(rendered)
					rendition:uploadFailed("Master is outside the source root: " .. masterFolder)
				elseif rel == "" then
					targetDir = root
				else
					targetDir = LrPathUtils.child(root, rel)
				end
			end

			if targetDir then
				LrFileUtils.createAllDirectories(targetDir)
				local stem = LrPathUtils.removeExtension(
					rendition.photo:getFormattedMetadata("fileName"))
				local name = stem .. (settings.filenameSuffix or "")
					.. "." .. LrPathUtils.extension(rendered)
				local target = LrPathUtils.child(targetDir, name)
				local recorded = rendition.publishedPhotoId

				if claimed[target] then
					LrFileUtils.delete(rendered)
					rendition:uploadFailed("Two photos publish to the same file: " .. target
						.. ". Rename one master or give the virtual copy its own name.")
				elseif LrFileUtils.exists(target) and recorded ~= target then
					LrFileUtils.delete(rendered)
					rendition:uploadFailed(name
						.. " already exists but was not published by this plugin; not overwriting.")
				else
					claimed[target] = true

					-- Land the render next to the target, then move into place,
					-- so a crash never leaves a truncated file under the published name.
					local partial = target .. ".part"
					LrFileUtils.delete(partial)
					LrFileUtils.copy(rendered, partial)
					LrFileUtils.delete(rendered)

					if LrFileUtils.exists(partial) ~= "file" then
						rendition:uploadFailed("Could not write to " .. targetDir)
					else
						LrFileUtils.delete(target)
						LrFileUtils.move(partial, target)
						if LrFileUtils.exists(target) == "file" then
							rendition:recordPublishedPhotoId(target)
							if recorded and recorded ~= target then
								applyOnRemove(settings.onRemove, recorded)
							end
						else
							LrFileUtils.delete(partial)
							rendition:uploadFailed("Could not move rendered file into " .. targetDir)
						end
					end
				end
			end
		end
	end
end

function provider.deletePhotosFromPublishedCollection(publishSettings, photoIds, deletedCallback)
	for _, path in ipairs(photoIds) do
		applyOnRemove(publishSettings.onRemove, path)
		deletedCallback(path)
	end
end

return provider
