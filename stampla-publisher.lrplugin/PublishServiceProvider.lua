local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrErrors = import "LrErrors"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrPrefs = import "LrPrefs"
local LrView = import "LrView"

local bind = LrView.bind

local provider = {}

provider.supportsIncrementalPublish = "only"
provider.canExportVideo = true
provider.hideSections = { "exportLocation", "fileNaming" }

provider.exportPresetFields = {
	{ key = "publishRoot", default = "" },
	{ key = "folderLayout", default = "collections" },
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
					title = "Folder structure:",
					alignment = "right",
					width = LrView.share "stampla_label",
				},
				f:popup_menu {
					value = bind "folderLayout",
					items = {
						{ title = "From collections", value = "collections" },
						{ title = "From catalog folders", value = "mirror" },
					},
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
					width_in_chars = 12,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = "",
					width = LrView.share "stampla_label",
				},
				f:column {
					f:static_text {
						title = "{ext} — the master's file extension",
						font = "<system/small>",
					},
					f:static_text {
						title = "{ext:lc} / {ext:uc} — lowercased / uppercased",
						font = "<system/small>",
					},
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

-- The filename suffix understands {token} and {token:modifier} forms,
-- e.g. _{ext}_lr publishes photo.nef as photo_nef_lr.jpg. Tokens are
-- computed per photo; registries below are the extension points.
local SUFFIX_TOKENS = { ext = true }
local SUFFIX_MODIFIERS = { lc = string.lower, uc = string.upper }

local function parseToken(body)
	local token, modifier = body:match("^(%w+):(%w+)$")
	if token then
		return token, modifier
	end
	return body:match("^(%w+)$"), nil
end

-- First unsupported {…} construct in the template, or nil if all valid.
local function badTokenIn(template)
	for body in template:gmatch("{([^{}]*)}") do
		local token, modifier = parseToken(body)
		if not (token and SUFFIX_TOKENS[token])
			or (modifier and not SUFFIX_MODIFIERS[modifier]) then
			return "{" .. body .. "}"
		end
	end
	return nil
end

local function expandSuffix(template, values)
	return (template:gsub("{([^{}]*)}", function(body)
		local token, modifier = parseToken(body)
		local value = values[token]
		if modifier then
			value = SUFFIX_MODIFIERS[modifier](value)
		end
		return value
	end))
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
	if not path or mode == "leave" or LrFileUtils.exists(path) ~= "file" then
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

	local suffixTemplate = settings.filenameSuffix or ""
	local badToken = badTokenIn(suffixTemplate)
	if badToken then
		LrErrors.throwUserError("Unknown token " .. badToken
			.. " in the filename suffix. Supported: {ext}, {ext:lc}, {ext:uc}.")
	end

	local layout = settings.folderLayout or "collections"
	local collectionDir
	local mirrorRoots

	if layout == "mirror" then
		-- Mirror the catalog's Folders panel: each master publishes to its
		-- folder path relative to the catalog root folder containing it.
		-- Longest root wins, in case roots nest.
		mirrorRoots = {}
		for _, folder in ipairs(LrApplication.activeCatalog():getFolders()) do
			mirrorRoots[#mirrorRoots + 1] = folder:getPath()
		end
		table.sort(mirrorRoots, function(a, b)
			return #a > #b
		end)
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
				local rel
				for _, rootPath in ipairs(mirrorRoots) do
					rel = relativeTo(rootPath, masterFolder)
					if rel then
						break
					end
				end
				if rel == nil then
					targetDir = nil
					LrFileUtils.delete(rendered)
					rendition:uploadFailed("Master is not under any catalog folder: "
						.. masterFolder)
				elseif rel == "" then
					targetDir = root
				else
					targetDir = LrPathUtils.child(root, rel)
				end
			end

			if targetDir then
				LrFileUtils.createAllDirectories(targetDir)
				local masterName = rendition.photo:getFormattedMetadata("fileName")
				local stem = LrPathUtils.removeExtension(masterName)
				local suffix = expandSuffix(suffixTemplate, {
					ext = LrPathUtils.extension(masterName) or "",
				})
				local name = stem .. suffix .. "." .. LrPathUtils.extension(rendered)
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

local function onRemoveDescription(mode)
	if mode == "delete" then
		return "permanently deleted"
	end
	return "moved to the trash"
end

local function forEachPublishedPhoto(collectionOrSet, fn)
	if collectionOrSet:type() == "LrPublishedCollection" then
		for _, publishedPhoto in ipairs(collectionOrSet:getPublishedPhotos()) do
			fn(publishedPhoto)
		end
	else
		for _, child in ipairs(collectionOrSet:getChildCollections()) do
			forEachPublishedPhoto(child, fn)
		end
		for _, childSet in ipairs(collectionOrSet:getChildCollectionSets()) do
			forEachPublishedPhoto(childSet, fn)
		end
	end
end

function provider.shouldDeletePublishedCollection(publishSettings, info)
	if publishSettings.onRemove == "leave" or not info.hasItemsOnService then
		return nil
	end
	local answer = LrDialogs.confirm(
		"Delete this published collection?",
		"Its published files will be " .. onRemoveDescription(publishSettings.onRemove) .. ".",
		"Delete", "Cancel")
	return answer == "ok" and "delete" or "cancel"
end

function provider.deletePublishedCollection(publishSettings, info)
	local removed = {}
	for _, path in ipairs(info.photoIds or {}) do
		removed[path] = true
		applyOnRemove(publishSettings.onRemove, path)
	end
	-- Deleting a whole collection set: photoIds covers a single collection,
	-- so walk the descendants too. The pcall guards against the collection
	-- objects already being gone; applyOnRemove tolerates repeats.
	pcall(function()
		forEachPublishedPhoto(info.publishedCollection, function(publishedPhoto)
			local path = publishedPhoto:getRemoteId()
			if path and not removed[path] then
				applyOnRemove(publishSettings.onRemove, path)
			end
		end)
	end)
end

function provider.shouldDeletePublishService(publishSettings, info)
	if publishSettings.onRemove == "leave" or (info.nPhotos or 0) == 0 then
		return nil
	end
	local answer = LrDialogs.confirm(
		"Delete this publish service?",
		"Its published files will be " .. onRemoveDescription(publishSettings.onRemove) .. ".",
		"Delete", "Cancel")
	return answer == "ok" and "delete" or "cancel"
end

function provider.willDeletePublishService(publishSettings, info)
	local service = info.publishService
	for _, collection in ipairs(service:getChildCollections()) do
		forEachPublishedPhoto(collection, function(publishedPhoto)
			applyOnRemove(publishSettings.onRemove, publishedPhoto:getRemoteId())
		end)
	end
	for _, childSet in ipairs(service:getChildCollectionSets()) do
		forEachPublishedPhoto(childSet, function(publishedPhoto)
			applyOnRemove(publishSettings.onRemove, publishedPhoto:getRemoteId())
		end)
	end
end

-- Flag every published photo in the given collections/sets as edited, so
-- the next Publish rewrites it. Returns false if the catalog write failed.
local function markForRepublish(collectionsOrSets)
	return (pcall(function()
		local catalog = LrApplication.activeCatalog()
		catalog:withWriteAccessDo("Mark to republish", function()
			for _, node in ipairs(collectionsOrSets) do
				forEachPublishedPhoto(node, function(publishedPhoto)
					publishedPhoto:setEditedFlag(true)
				end)
			end
		end, { timeout = 30 })
	end))
end

local function warnMarkFailed(what)
	LrDialogs.message("Stampla Publisher",
		"Could not mark " .. what .. " to republish."
			.. " Select the photos and use Mark to Republish, then publish.", "warning")
end

-- Renaming or re-nesting a collection retargets every photo in it, but
-- Lightroom does not queue them on its own: flag them so the next Publish
-- heals the tree. Irrelevant in mirror layout, where collections do not
-- influence the target path.
function provider.renamePublishedCollection(publishSettings, info)
	if publishSettings.folderLayout == "mirror" then
		return
	end
	if not markForRepublish({ info.publishedCollection }) then
		warnMarkFailed("the collection's photos")
	end
end

provider.reparentPublishedCollection = provider.renamePublishedCollection

-- Changing the publish root, folder structure or suffix retargets every
-- published photo, and Lightroom does not queue anything when settings
-- change. A fingerprint of the naming-affecting settings is kept per
-- service; when it changes, offer to mark everything for republish.
local function namingFingerprint(settings)
	return table.concat({
		settings.publishRoot or "",
		settings.folderLayout or "collections",
		settings.filenameSuffix or "",
	}, "\n")
end

function provider.didCreateNewPublishService(publishSettings, info)
	local prefs = LrPrefs.prefsForPlugin()
	prefs["naming_" .. info.publishService.localIdentifier] = namingFingerprint(publishSettings)
end

function provider.didUpdatePublishService(publishSettings, info)
	local prefs = LrPrefs.prefsForPlugin()
	local key = "naming_" .. info.publishService.localIdentifier
	local before = prefs[key]
	local now = namingFingerprint(publishSettings)
	prefs[key] = now
	if not before or before == now then
		return
	end

	local service = info.publishService
	local nodes = {}
	for _, collection in ipairs(service:getChildCollections()) do
		nodes[#nodes + 1] = collection
	end
	for _, childSet in ipairs(service:getChildCollectionSets()) do
		nodes[#nodes + 1] = childSet
	end

	local anyPublished = false
	for _, node in ipairs(nodes) do
		forEachPublishedPhoto(node, function()
			anyPublished = true
		end)
		if anyPublished then
			break
		end
	end
	if not anyPublished then
		return
	end

	local answer = LrDialogs.confirm(
		"Publish settings affecting file names or locations changed.",
		"Mark all published photos to republish? The next publish then rebuilds"
			.. " the tree, applying the on-remove setting to the old files.",
		"Mark to Republish", "Not Now")
	if answer == "ok" and not markForRepublish(nodes) then
		warnMarkFailed("the published photos")
	end
end

return provider
