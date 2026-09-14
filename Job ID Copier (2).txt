local jobId = game.JobId
if setclipboard then
    setclipboard(jobId)
elseif toclipboard then
    toclipboard(jobId)
end
print("Job ID: " .. jobId)
