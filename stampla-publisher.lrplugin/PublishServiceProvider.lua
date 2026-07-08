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
	local collectionName = exportContext.publishedCollectionInfo.name

	local root = settings.publishRoot
	if not root or root == "" then
		LrErrors.throwUserError("Set a publish root in the publish service settings.")
	end
	if LrFileUtils.exists(root) ~= "directory" then
		LrErrors.throwUserError("Publish root does not exist: " .. root)
	end

	local targetDir = LrPathUtils.child(root, collectionName)
	LrFileUtils.createAllDirectories(targetDir)

	local nRenditions = exportContext.exportSession:countRenditions()
	exportContext:configureProgress {
		title = string.format("Publishing %d file%s to %s",
			nRenditions, nRenditions == 1 and "" or "s", collectionName),
	}

	local claimed = {}

	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		local ok, rendered = rendition:waitForRender()
		if ok then
			local stem = LrPathUtils.removeExtension(
				rendition.photo:getFormattedMetadata("fileName"))
			local name = stem .. (settings.filenameSuffix or "")
				.. "." .. LrPathUtils.extension(rendered)
			local target = LrPathUtils.child(targetDir, name)
			local recorded = rendition.publishedPhotoId

			if claimed[target] then
				LrFileUtils.delete(rendered)
				rendition:uploadFailed("Two photos in this collection publish to the same name: "
					.. name .. ". Rename one master or publish the virtual copy elsewhere.")
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

function provider.deletePhotosFromPublishedCollection(publishSettings, photoIds, deletedCallback)
	for _, path in ipairs(photoIds) do
		applyOnRemove(publishSettings.onRemove, path)
		deletedCallback(path)
	end
end

return provider
