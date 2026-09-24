--!strict
--- Instance helpers the plugin's entry script and its editor share.
local Instances = {}

--- Destroys the children of `Parent` that are of `Class`, leaving layouts and the like in place.
function Instances.ClearChildrenWhichAre(Parent: Instance, Class: string)
	for _, Child in Parent:GetChildren() do
		if Child:IsA(Class) then
			Child:Destroy()
		end
	end
end

return Instances
