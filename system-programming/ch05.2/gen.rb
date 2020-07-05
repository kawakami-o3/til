#!/usr/bin/ruby
#

#fname = "copy2_highio"
%W[copy2_highio copy2_lowio].each do |fname|
  cnt = open("#{fname}.c.base").read

  %W[256 512 1024 2048 4096 8192 16384].each do |i|
    n = sprintf("%05d", i.to_i)
    oname = "#{fname}_#{n}.c"
    #p oname
    #puts cnt.gsub(/NNN/, i)

    open(oname, "w") do |f|
      f.puts(cnt.gsub(/NNN/, i))
    end
  end
end
