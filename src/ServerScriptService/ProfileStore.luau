--!strict
-- UpdateAsync is the only persistence path. Tests may inject store/clock/wait/token.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ProfileStore = {}
ProfileStore.__index = ProfileStore
local LEASE_SECONDS = 120
local ATTEMPTS = 3

function ProfileStore.new(options: any): any
	local self: any = setmetatable({}, ProfileStore)
	self.store = options.store or DataStoreService:GetDataStore("HookmanProfile_v1")
	self.clock = options.clock or os.time
	self.wait = options.wait or task.wait
	self.token = options.token or function()
		return HttpService:GenerateGUID(false)
	end
	self.jobId = options.jobId or game.JobId
	self.sanitize = options.sanitize
	self.serialize = options.serialize
	self.onLost = options.onLost
	self.sessions = {}
	return self
end

local function owns(self: any, record: any, session: any): boolean
	local lease = type(record) == "table" and record._session
	return type(lease) == "table"
		and lease.jobId == self.jobId
		and lease.token == session.token
		and type(lease.expires) == "number"
		and lease.expires == lease.expires
		and lease.expires > self.clock()
		and lease.expires < math.huge
end

function ProfileStore.lose(self: any, session: any)
	if session.lost then
		return
	end
	session.lost = true
	if self.onLost then
		self.onLost(session.userId)
	end
end

function ProfileStore.isReady(self: any, session: any): boolean
	if not session or session.closed or session.closing or session.lost then
		return false
	end
	if self.clock() >= session.expires then
		self:lose(session)
		return false
	end
	return true
end

function ProfileStore.acquire(self: any, userId: number, cancelled: () -> boolean): any
	if self.sessions[userId] then
		return nil
	end
	local session: any = {
		userId = userId,
		token = self.token(),
		loading = true,
		revision = 0,
		savedRevision = 0,
		busy = false,
		expires = 0,
	}
	self.sessions[userId] = session
	for attempt = 1, ATTEMPTS do
		if cancelled() then
			break
		end
		local ok, record = pcall(function()
			return self.store:UpdateAsync("p" .. userId, function(raw: any)
				if cancelled() then
					return nil
				end
				local lease = type(raw) == "table" and raw._session
				if type(lease) == "table" then
					local expiry = lease.expires
					-- Malformed leases are not safe to steal.
					if type(expiry) ~= "number" or expiry ~= expiry or math.abs(expiry) == math.huge then
						return nil
					end
					if expiry > self.clock() and not (lease.jobId == self.jobId and lease.token == session.token) then
						return nil
					end
				end
				local clean = self.serialize(self.sanitize(raw))
				clean._session = { jobId = self.jobId, token = session.token, expires = self.clock() + LEASE_SECONDS }
				return clean
			end)
		end)
		if ok and owns(self, record, session) then
			session.profile = self.sanitize(record)
			session.expires = record._session.expires
			session.savedData = self.serialize(session.profile)
			session.loading = false
			if cancelled() then
				self:release(session)
				return nil
			end
			return session
		end
		if attempt < ATTEMPTS then
			self.wait(attempt)
		end
	end
	-- An errored response may still have committed our acquisition. Release only our token.
	self:release(session)
	return nil
end

function ProfileStore.markDirty(self: any, session: any): number
	if not self:isReady(session) then
		return session.revision
	end
	session.revision += 1
	return session.revision
end

function ProfileStore.save(self: any, session: any, requiredRevision: number?): (boolean, any)
	local target = requiredRevision or session.revision
	local deadline = self.clock() + 20
	while session.busy do
		if not self:isReady(session) or self.clock() >= deadline then
			return false, nil
		end
		self.wait(0.05)
	end
	if not self:isReady(session) then
		return false, nil
	end
	session.busy = true
	local revision = session.revision
	local data = self.serialize(session.profile)
	local success = false
	for attempt = 1, ATTEMPTS do
		if not self:isReady(session) or self.clock() >= deadline then
			break
		end
		local rejected = false
		local ok, record = pcall(function()
			return self.store:UpdateAsync("p" .. session.userId, function(raw: any)
				if session.lost or session.closed or not owns(self, raw, session) then
					rejected = true
					return nil
				end
				local nextRecord = table.clone(data)
				nextRecord._session =
					{ jobId = self.jobId, token = session.token, expires = self.clock() + LEASE_SECONDS }
				return nextRecord
			end)
		end)
		if ok and owns(self, record, session) then
			session.expires = record._session.expires
			session.savedRevision = revision
			session.savedData = data
			success = true
			break
		end
		if ok and rejected then
			self:lose(session)
			break
		end
		if attempt < ATTEMPTS then
			self.wait(attempt)
		end
	end
	session.busy = false
	if self.clock() >= session.expires then
		self:lose(session)
	end
	return success and session.savedRevision >= target, success and session.savedData or nil
end

function ProfileStore.release(self: any, session: any): (boolean, any)
	if session.closed then
		return true, nil
	end
	if session.closing then
		return false, nil
	end
	session.closing = true -- Economic writes stop before waiting for an in-flight save.
	local deadline = self.clock() + 20
	while session.busy and self.clock() < deadline do
		self.wait(0.05)
	end
	if session.busy then
		return false, nil
	end
	local data = session.profile and self.serialize(session.profile)
	local released = false
	local savedData = nil
	for attempt = 1, ATTEMPTS do
		if self.clock() >= deadline or session.lost then
			break
		end
		local ok, record = pcall(function()
			return self.store:UpdateAsync("p" .. session.userId, function(raw: any)
				local lease = type(raw) == "table" and raw._session
				if type(lease) ~= "table" or lease.jobId ~= self.jobId or lease.token ~= session.token then
					return nil
				end
				-- An expired/uncertain acquisition may only drop its own metadata, never save data.
				local nextRecord = data and owns(self, raw, session) and table.clone(data) or table.clone(raw)
				nextRecord._session = nil
				return nextRecord
			end)
		end)
		if ok then
			released = true
			if type(record) == "table" and record._session == nil then
				savedData = record
			end
			break
		end
		if attempt < ATTEMPTS then
			self.wait(attempt)
		end
	end
	session.closed = true
	if self.sessions[session.userId] == session then
		self.sessions[session.userId] = nil
	end
	return released, savedData
end

return ProfileStore
