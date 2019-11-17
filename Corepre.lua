--Map Replacements (WIP)
RestorationMapFramework = RestorationMapFramework or class(MapFramework)

RestorationMapFramework._directory = ModPath .. "map_replacements"
RestorationMapFramework.type_name = "restoration"

if restoration and restoration.Options:GetValue("SC/SC") then
	RestorationMapFramework:new()
	if not PackageManager:loaded("packages/scassets") then
		PackageManager:load("packages/scassets")
	end
 	if not PackageManager:loaded("packages/boilersuitsXD") then
	 	PackageManager:load("packages/boilersuitsXD")
	end	
	if not PackageManager:loaded("packages/outfits") then
		PackageManager:load("packages/outfits")
   end
end
-- Always load
if not PackageManager:loaded("packages/addhudmisc") then
	PackageManager:load("packages/addhudmisc")
end
