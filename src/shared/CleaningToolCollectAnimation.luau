-- Compatibility module for cleaning Tool LocalScripts that still call Bind(tool).
-- Collection animations are handled centrally by client/Controllers/ToolController,
-- so this binding intentionally does not install a second animation listener.
local CleaningToolCollectAnimation = {}

function CleaningToolCollectAnimation.Bind(_tool: Tool)
	-- Kept for compatibility with existing Tool LocalScripts.
end

return table.freeze(CleaningToolCollectAnimation)
