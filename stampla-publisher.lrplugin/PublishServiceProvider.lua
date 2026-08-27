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

-- Collection (set) names become folder names in the collections layout;
-- separators or Windows-illegal characters would silently nest folders
-- or fail every copy with a misleading error.
function provider.validatePublishedCollectionName(name)
	return name:match('[\\/:*?"<>|]') == nil
end

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
						title = "{ext} — the original file's extension",
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

-- Path of `path` relative to `root`: "" if equal, nil if outside. The
-- prefix comparison folds case — macOS and Windows filesystems do.
local function relativeTo(root, path)
	local last = root:sub(-1)
	if last == "/" or last == "\\" then
		root = root:sub(1, -2)
	end
	if path:lower() == root:lower() then
		return ""
	end
	local boundary = path:sub(#root + 1, #root + 1)
	if path:sub(1, #root):lower() == root:lower() and (boundary == "/" or boundary == "\\") then
		return path:sub(#root + 2)
	end
	return nil
end

-- Path identity: LrC runs on case-insensitive filesystems, and the same
-- folder can be spelled /Volumes/Mirror or /volumes/mirror/ — a byte
-- comparison would wedge every rendition behind "not published by this
-- plugin" after a respelled root.
local function canonical(path)
	if not path then
		return nil
	end
	return LrPathUtils.standardizePath(path):lower()
end

-- LrPrefs are plugin-global while localIdentifier is only unique per
-- catalog; two catalogs would otherwise cross-contaminate fingerprints.
local function namingPrefsKey(service)
	local catalogPath = LrApplication.activeCatalog():getPath()
	return "naming_" .. catalogPath .. ":" .. service.localIdentifier
end

local function samePath(a, b)
	if a == b then
		return true
	end
	if not a or not b then
		return false
	end
	return canonical(a) == canonical(b)
end

-- Returns true when the published file is gone; false when it still
-- exists and could not be removed (locked, no-trash volume) — the
-- caller must then keep the photo recorded instead of forgetting it.
local function applyOnRemove(mode, path)
	if not path or mode == "leave" or LrFileUtils.exists(path) ~= "file" then
		return true
	end
	if mode == "delete" then
		LrFileUtils.delete(path)
	else
		LrFileUtils.moveToTrash(path)
	end
	return LrFileUtils.exists(path) ~= "file"
end

-- Copy `rendered` under the published name without ever destroying the
-- previous published file before its replacement is safely in place.
-- Returns true on success (and consumes `rendered`), or false plus a
-- user-facing reason (leaving `rendered` for the caller to clean up).
local function publishInto(rendered, target)
	local targetDir = LrPathUtils.parent(target)
	local partial = target .. ".part"
	LrFileUtils.delete(partial)
	local renderedAttrs = LrFileUtils.fileAttributes(rendered)
	LrFileUtils.copy(rendered, partial)
	local partialAttrs = LrFileUtils.exists(partial) == "file"
		and LrFileUtils.fileAttributes(partial) or nil
	if not partialAttrs or not renderedAttrs
		or partialAttrs.fileSize ~= renderedAttrs.fileSize then
		-- a short copy (full disk) must never become the published file
		LrFileUtils.delete(partial)
		return false, "Could not write a complete copy to " .. targetDir
	end

	local backup
	if LrFileUtils.exists(target) == "file" then
		-- park the old file instead of deleting it: if the move below
		-- fails, the mirror keeps the previous version, never a hole
		backup = target .. ".bak"
		LrFileUtils.delete(backup)
		LrFileUtils.move(target, backup)
		if LrFileUtils.exists(target) then
			LrFileUtils.delete(partial)
			return false, "Could not move the previous published file aside: " .. target
		end
	elseif LrFileUtils.exists(target) then
		LrFileUtils.delete(partial)
		return false, target .. " exists but is not a file; not replacing it."
	end

	LrFileUtils.move(partial, target)
	if LrFileUtils.exists(target) ~= "file" then
		if backup then
			LrFileUtils.move(backup, target)
		end
		LrFileUtils.delete(partial)
		return false, "Could not move the rendered file into " .. targetDir
	end
	if backup then
		LrFileUtils.delete(backup)
	end
	LrFileUtils.delete(rendered)
	return true
end

function provider.processRenderedPhotos(_, exportContext)
	local settings = exportContext.propertyTable
	local collectionInfo = exportContext.publishedCollectionInfo
	local collectionName = collectionInfo.name

	local root = settings.publishRoot
	if not root or root == "" then
		LrErrors.throwUserError("Set a publish root in the publish service settings.")
	end
	root = LrPathUtils.standardizePath(root)
	if LrFileUtils.exists(root) ~= "directory" then
		LrErrors.throwUserError("Publish root does not exist: " .. root)
	end

	local suffixTemplate = settings.filenameSuffix or ""
	local badToken = badTokenIn(suffixTemplate)
	if badToken then
		LrErrors.throwUserError("Unknown token " .. badToken
			.. " in the filename suffix. Supported: {ext}, {ext:lc}, {ext:uc}.")
	end
	local literals = suffixTemplate:gsub("{[^{}]*}", "")
	if literals:match('[\\/:*?"<>|]') then
		LrErrors.throwUserError("The filename suffix contains a path separator or a"
			.. ' character Windows forbids (\\ / : * ? " < > |).')
	end

	local layout = settings.folderLayout or "collections"
	local collectionDir
	local mirrorRoots

	if layout == "mirror" then
		-- Mirror the catalog's Folders panel: each photo publishes to its
		-- original's folder path relative to the catalog root folder containing it.
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

	local function processOne(rendition, rendered)
		local targetDir = collectionDir
		if layout == "mirror" then
			local originalFolder = LrPathUtils.parent(
				rendition.photo:getRawMetadata("path"))
			local rel
			for _, rootPath in ipairs(mirrorRoots) do
				rel = relativeTo(rootPath, originalFolder)
				if rel then
					break
				end
			end
			if rel == nil then
				LrFileUtils.delete(rendered)
				rendition:uploadFailed("The photo's original file is not under any catalog folder: "
					.. originalFolder)
				return
			elseif rel == "" then
				targetDir = root
			else
				targetDir = LrPathUtils.child(root, rel)
			end
		end

		LrFileUtils.createAllDirectories(targetDir)
		local originalName = rendition.photo:getFormattedMetadata("fileName")
		local stem = LrPathUtils.removeExtension(originalName)
		local suffix = expandSuffix(suffixTemplate, {
			ext = LrPathUtils.extension(originalName) or "",
		})
		local name = stem .. suffix .. "." .. LrPathUtils.extension(rendered)
		local target = LrPathUtils.child(targetDir, name)
		local recorded = rendition.publishedPhotoId

		if claimed[canonical(target)] then
			LrFileUtils.delete(rendered)
			rendition:uploadFailed("Two photos publish to the same file: " .. target
				.. ". Rename one original, or publish only one of the copies from"
				.. " this collection (virtual copies share the original's name).")
		elseif LrFileUtils.exists(target) and not samePath(recorded, target) then
			LrFileUtils.delete(rendered)
			local why = name
				.. " already exists but is not recorded for this photo; not overwriting."
			if layout == "mirror" then
				why = why .. " In the mirror layout, publish each photo from one"
					.. " collection only — every collection targets the same tree."
			end
			rendition:uploadFailed(why)
		else
			claimed[canonical(target)] = true
			local okPublish, why = publishInto(rendered, target)
			if okPublish then
				rendition:recordPublishedPhotoId(target)
				if recorded and not samePath(recorded, target) then
					applyOnRemove(settings.onRemove, recorded)
				end
			else
				LrFileUtils.delete(rendered)
				rendition:uploadFailed(why)
			end
		end
	end

	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		local ok, rendered = rendition:waitForRender()
		if ok then
			-- one unexpected error fails this rendition, not the whole queue
			local processed, err = pcall(processOne, rendition, rendered)
			if not processed then
				pcall(LrFileUtils.delete, rendered)
				pcall(function()
					rendition:uploadFailed("Unexpected error: " .. tostring(err))
				end)
			end
		end
	end
end

function provider.deletePhotosFromPublishedCollection(publishSettings, photoIds, deletedCallback)
	local root = publishSettings.publishRoot
	if publishSettings.onRemove ~= "leave"
		and (not root or LrFileUtils.exists(root) ~= "directory") then
		-- an unmounted mirror must not make Lightroom forget the photos
		-- while their files live on: nothing is confirmed removed
		LrDialogs.message("Stampla Publisher",
			"The publish root is not reachable (" .. tostring(root)
				.. ") — nothing was removed. Mount it and remove again.", "warning")
		return
	end
	local failed = 0
	for _, path in ipairs(photoIds) do
		if applyOnRemove(publishSettings.onRemove, path) then
			deletedCallback(path)
		else
			failed = failed + 1
		end
	end
	if failed > 0 then
		LrDialogs.message("Stampla Publisher",
			failed .. " published file(s) could not be removed and stay recorded —"
				.. " check permissions, then remove again.", "warning")
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
	-- per-node pcall: one collection mid-teardown must not strand the rest
	for _, collection in ipairs(service:getChildCollections()) do
		pcall(forEachPublishedPhoto, collection, function(publishedPhoto)
			applyOnRemove(publishSettings.onRemove, publishedPhoto:getRemoteId())
		end)
	end
	for _, childSet in ipairs(service:getChildCollectionSets()) do
		pcall(forEachPublishedPhoto, childSet, function(publishedPhoto)
			applyOnRemove(publishSettings.onRemove, publishedPhoto:getRemoteId())
		end)
	end
	pcall(function()
		LrPrefs.prefsForPlugin()[namingPrefsKey(service)] = nil
	end)
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

-- Renaming or re-nesting a SET retargets its entire subtree the same way
-- — every descendant collection's folder path contains the set's name.
function provider.renamePublishedCollectionSet(publishSettings, info)
	if publishSettings.folderLayout == "mirror" then
		return
	end
	if not markForRepublish({ info.publishedCollectionSet }) then
		warnMarkFailed("the set's photos")
	end
end

provider.reparentPublishedCollectionSet = provider.renamePublishedCollectionSet

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
	prefs[namingPrefsKey(info.publishService)] = namingFingerprint(publishSettings)
end

function provider.didUpdatePublishService(publishSettings, info)
	local prefs = LrPrefs.prefsForPlugin()
	local key = namingPrefsKey(info.publishService)
	local before = prefs[key]
	local now = namingFingerprint(publishSettings)
	if not before or before == now then
		-- services from before fingerprinting adopt their first observed
		-- settings as the baseline; nothing to compare against yet
		prefs[key] = now
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
		prefs[key] = now
		return
	end

	local answer = LrDialogs.confirm(
		"Publish settings affecting file names or locations changed.",
		"Mark all published photos to republish? The next publish then rebuilds"
			.. " the tree, applying the on-remove setting to the old files."
			.. " Choosing Not Now asks again after the next settings change.",
		"Mark to Republish", "Not Now")
	if answer ~= "ok" then
		-- keep the old fingerprint: the mirror is still inconsistent, and
		-- a kept baseline means the next settings edit re-offers the fix
		return
	end
	prefs[key] = now
	if not markForRepublish(nodes) then
		warnMarkFailed("the published photos")
	end
end

return provider
