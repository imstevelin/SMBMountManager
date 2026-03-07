require 'xcodeproj'

project_path = 'SMBMountManager.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'SMBMountManager' }
if target.nil?
  puts "Target SMBMountManager not found."
  exit 1
end

# Check if an Embed Frameworks phase already exists
embed_phase = target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
if embed_phase.nil?
  puts "Creating 'Embed Frameworks' build phase."
  embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  embed_phase.name = 'Embed Frameworks'
  embed_phase.symbol_dst_subfolder_spec = :frameworks
  target.build_phases << embed_phase
else
  puts "'Embed Frameworks' build phase already exists."
end

# Find the AMSMB2 product reference
amsmb2_ref = project.frameworks_group.files.find { |f| f.path == 'AMSMB2' || f.name == 'AMSMB2' }

if amsmb2_ref.nil?
  puts "AMSMB2 framework reference not found in Frameworks group. Looking in dependencies..."
  # If it's a Swift Package dependency, we might not find it as a simple file ref.
  # Let's try to add it.
  
  # For Swift Packages, the product reference is usually found in package_product_dependencies
  deps = target.package_product_dependencies.find { |d| d.product_name == 'AMSMB2' }
  if deps
     puts "Found Swift Package dependency for AMSMB2."
     
     # We need to find the PBXBuildFile for AMSMB2 that is in the Frameworks build phase
     framework_phase = target.frameworks_build_phase
     build_file = framework_phase.files.find { |f| f.product_ref && f.product_ref.product_name == 'AMSMB2' }
     
     if build_file && build_file.product_ref
       amsmb2_ref = build_file.product_ref
       puts "Found product reference from Frameworks phase."
     else
       puts "Could not find PBXBuildFile for AMSMB2."
       exit 1
     end
  else
    puts "Could not find AMSMB2 dependency."
    exit 1
  end
end

# Check if it's already in the Embed Frameworks phase
if embed_phase.files.any? { |f| f.product_ref == amsmb2_ref || f.file_ref == amsmb2_ref }
  puts "AMSMB2 is already embedded."
else
  puts "Adding AMSMB2 to 'Embed Frameworks' phase."
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = amsmb2_ref
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  embed_phase.files << build_file
end

project.save
puts "Successfully updated project.pbxproj."
