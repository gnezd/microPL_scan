# Script for the processing of micro-PL scann data
# Objective: iterate through lines, assign some sort of sum(s) to frame and output as:
# frame# sum1 sum2 ...

# Todo: classes raw, spect, and....?
# Sum up frame and create pixel value. scan should be array fornow
# format: [path, scan_name, width, height]
# Todo: accecpt code block for summing. Tricky: injection to whole loop
# In general, mode extraction can be representated as a matrix acting on a spectrum but this requires spectrum spectrum constructing and lacks the freedom of passing blocks and conditions
# An even more general way of doing things is to pass into sum_up() a list of criteria on the wavelengths
require 'gsl'
require 'nokogiri'

def plot_map(scan, sum = nil)
  if sum == nil
    sum = Proc.new {|spect| (spect.map{|pt| pt[1]}).sum}
  end
  maps = []
  # Iterate through z layers
  (0..scan.depth-1).each do |z|
    map = Array.new(scan.width) {Array.new(scan.height) {0.0}} # One slice
    (0..scan.width-1).each do |x|
      (0..scan.height-1).each do |y|
        map[x][y] = sum[scan[x][y][z]]
      end
    end

    # Export map and push
    map_fout = File.open "output/#{scan.name}_#{z}.tsv", 'w'
    map.transpose.each do |row|
      map_fout.puts row.join "\t"
    end
    map_fout.close
    maps.push map

    # Plotting
    gplot = File.open "output/#{scan.name}_#{z}.gplot", 'w'
gplot_content =<<GPLOT_HEAD
set terminal svg size #{scan.width * 5},#{scan.height * 5} mouse enhanced standalone
set output 'output/#{scan.name}_#{z}.svg'
set border 0
unset key
unset xtics
unset ytics
set xrange[-0.5:#{scan.width}-0.5]
set yrange[-0.5:#{scan.height}-0.5]
set title '#{scan.name.gsub('_','\_')}-#{z}'
unset colorbox
set palette cubehelix negative
plot 'output/#{scan.name}_#{z}.tsv' matrix with image pixels
set terminal png size #{scan.width * 5},#{scan.height * 5}
set output 'output/#{scan.name}_#{z}.png'
replot
GPLOT_HEAD
    gplot.puts gplot_content
    gplot.close
    puts "Plotting #{scan.name}_#{z}, W: #{scan.width}, H: #{scan.height}"
    `gnuplot output/#{scan.name}_#{z}.gplot`
  end
end

# Return list of points in rectangular area defined by pt_1(x,y) to pt_2(x,y)
def select_points(pt_1, pt_2)
  raise "Not points" unless (pt_1.size == 3) && (pt_2.size == 3)
  result = []
  ([pt_1[0], pt_2[0]].sort[0]..[pt_1[0], pt_2[0]].sort[1]).each do |x|
    ([pt_1[1], pt_2[1]].sort[0]..[pt_1[1], pt_2[1]].sort[1]).each do |y|
      ([pt_1[2], pt_2[2]].sort[0]..[pt_1[2], pt_2[2]].sort[1]).each do |z|
        result.push [x,y,z]
      end
    end
  end
  result
end


class Scan < Array
  # Assume all wavelength scales allign across all pixels
  attr_accessor :frames, :wv, :spectrum_units,:path, :name, :width, :height, :depth
  def initialize (path, name, dim, options = nil)
    @path = path
    @name = name
    @width = dim[0]
    @height = dim[1]
    @depth = dim[2]
    @loaded = false
    @spectral_width = 0
    super Array.new(width) {Array.new(height) {Array.new(depth) {Spectrum.new()}}}
  end

  def load(options)
    case File.extname @path
    when /\.[cC][sS][vV]/
      load_csv options
    when /\.[sS][pP][eE]/
      load_spe options
    else
      raise "File extension of #{@path} not recognizable."
    end
  end

  def load_csv(options)
    fin = File.open @path, 'r'
    puts "Reading #{@path}..."
    lines = fin.readlines
    fin.close

    # Detection of seperator , or tab
    raiese "No seperator found in line 0." unless match = lines[0].match(/[\t,]/)
    seperator = match[0]

    # Detection of title line and units
    # Problem: even if the spectrum were in wavenumbers, the unit was still recorded as "Wavelength"
    if lines[0] =~ /^Frame[\t,]/
      title_line = lines.shift
      @spectrum_units = title_line.split(seperator)[1..2]
      puts "Title line detected. Unit identified as #{@wv_unit}"
    else
      puts "No title line detected. Please ensure data format to be <Frame #> <Wavelength/wavenumber> <Intensity>"
      puts "And input <wavelength/wavenumber, intensity> unit below:"
      @spectrum_units = gets.chomp.split /, ?/
    end

    # Framesize and wavelength construction
    @framesize = (lines.index {|ln| ln[0] == '2'})
    @wv = (0.. @framesize -1).map {|i| lines[i].split(seperator)[1]}
    puts "Frame size determined to be #{@framesize}, spectral range being #{@wv[0]} .. #{@wv[-1]}"
    @spectrum_units[0] = 'Wavenumber (cm-1)' if @wv[-1] < @wv[0]
    
    raise "Number of lines is #{lines.size}, not multiplication of given width (#{@width}) * height (#{@height})* depth (#{@depth})!" unless lines.size == @framesize * (@width * @height * @depth)
    puts "Got #{lines.size} lines of spectrum to process."

    # The real parsing
    lines.each do |line|
      (frame, wv, intensity) = line.split seperator
      frame = frame.to_i - 1 # Matter of convention. I count up from 0.
      wv = wv.to_f
      intensity = intensity.to_f
      k = frame / (@width * @height)
      j = (frame % (@width * @height)) / @width
      i = (frame % (@width * @height)) % @width

      # S-shape scan
      # Todo on the instrument part: make this optional. After that also make this an option here.
      if j % 2 == 0
        self[i][j][k].push [wv, intensity]
      else
        self[width-1-i][j][k].push [wv, intensity]
      end
    end
    # Update all spectra
    puts "Loading done. Updating info of spectra."
    self.each do |row|
      row.each do |column|
        column.each do |pixel|
          pixel.units = @spectrum_units
          pixel.update_info
        end
      end
    end
    @loaded = true
    puts "done"
  end

  def load_spe(options)
    # File read
    fin = File.open @path
    raw = fin.read.freeze
    fin.close
    xml_index = raw[678..685].unpack1('Q')

    binary_data = raw[0x1004..xml_index-1]
    unpacked_counts = binary_data.unpack('S*')
    xml = Nokogiri.XML(raw[xml_index..-1]).remove_namespaces!

    # ROI on CCD determines starting wavelength
    x0 = xml.xpath('//Calibrations/SensorMapping').attr('x').value.to_i
    @framesize = xml.xpath('//Calibrations/SensorMapping').attr('width').value.to_i
    @frames = xml.xpath('//DataFormat/DataBlock').attr('count').value.to_i
    wavelengths_nm = xml.xpath('//Calibrations/WavelengthMapping/Wavelength').text.split(',')[x0, @framesize].map {|x| x.to_f}
    @wv = wavelengths_nm.map {|nm| 10000000.0 / nm} # wavanumber

    raise "0_o unpacked ints has a length of #{unpacked_counts.size} for #{@name}. With framesize #{@framesize} we expect #{width} * #{height} * #{depth} * #{@framesize}." unless unpacked_counts.size == @width * @height * @depth* @framesize

    # Set unit and name
    @spectrum_units = ['wavenumber', 'counts']

    # Spectrum building
    (0..@width-1).each do |i|
      (0..@height-1).each do |j|
        if j % 2 == 1 && options['s_scan'] == true
          #puts "Loading spe assuming s_scan"
          relabel_i = @width - i - 1
        else
          relabel_i = i
        end
        (0..depth-1).each do |k|
          frame_st = (k * (@width * @height) + j * @width + i) * @framesize
          unpacked_counts[frame_st .. frame_st + @framesize - 1].each_with_index do |value, sp_index|
            self[relabel_i][j][k].push [@wv[sp_index], value]
          end
        end
      end
    end
    # Update spectra info
    (0..@width-1).each do |i|
      (0..@height-1).each do |j|
        (0..@depth-1).each do |k| 
          self[i][j][k].update_info
          self.spectrum_units = @spectrum_units
        end
      end
    end
  end

  def extract_spect(points)
    raise "Not a series of points input." unless (points.is_a? Array) && (points.all? {|item| item.size == 3})
    if !@loaded
      puts "Scan #{@name} not yet loaded. Loading."
      self.load
    end
    result = []
    points.each do |pt|
      result.push self[pt[0]][pt[1]][pt[2]]
      result.last.name = pt.join '-'
    end 
    result
  end

end

class Spectrum < Array
  attr_accessor :name, :units, :spectral_range, :signal_range, :desc
  def initialize(path=nil)
    @name = ''
    @desc = ''
    @units = ['', 'counts']
    super Array.new() {[0.0, 0.0]}
    # Load from tsv/csv if path given
    #if path && (File.exist? path) too gracious!
    if path
      fin = File.open path, 'r'
      lines = fin.readlines
      lines.shift if lines[0] =~ /^Frame[\t,]/
      # Detection of seperator , or tab
      if match = lines[0].match(/[\t,]/)
        puts "Loading from #{path}"
        seperator = match[0]
        lines.each_index do |i|
          (wv, intensity) = lines[i].split seperator
          wv = wv.to_f
          intensity = intensity.to_f
          self[i] = [wv, intensity]
        end
        @name = File.basename(path)
        update_info
      else
        puts "No seperator found in #{path}"
      end
    end
  end

  def write_tsv(outname)
    fout = File.open outname, 'w'
    self.each do |pt|
      fout.puts pt.join "\t"
    end
    fout.close
  end

  def inspect
    return { 'name' => @name, 'size' => self.size, 'spectral_range' => @spectral_range, 'signal_range' => @signal_range, 'desc' => @desc }.to_s
  end

  def update_info
    @spectral_range = self.minmax_by { |pt| pt[0] }.map{ |pt| pt[0] }
    @signal_range = self.minmax_by { |pt| pt[1] }.map{ |pt| pt[1] }
  end

  def ma(radius)
    # +- radius points moving average
    # Issue: Radius defined on no of points but not real spectral spread 
    raise "Radius should be integer but was given #{radius}" unless radius.is_a?(Integer)
    raise "Radius larger than half the length of spectrum" if 2*radius >= self.size

    result = Spectrum.new
    (0..self.size-2*radius-1).each do |i|
      # Note that the index i of the moving average chromatogram aligns with i + radius in originaal chromatogram
      x = self[i + radius][0]
      y = 0.0
      (i .. i + 2 * radius).each do |origin_i|
        # Second loop to run through the neighborhood in origin
        # Would multiplication with a diagonal stripe matrix be faster than nested loop? No idea just yet.
        y += self[origin_i][1]
      end
      y = y / (2 * radius + 1) # Normalization
      result[i] = [x, y]
    end
    result.units = @units
    result.name = @name + "-ma#{radius}"
    result.update_info
    result
  end

  def local_max(loosen = nil)
    raise "Loosen neighborhood should be number of points" unless loosen.is_a? Integer or loosen == nil
    result = []
    (1..self.size-2).each do |i|
      if self[i][1] > self[i+1][1] && self[i][1] > self[i-1][1]
        result.push self[i]
      end
    end

    loosened = []
    if loosen
      puts "start loosening with radius #{loosen}"
      i = 0
      while i < result.size - 1
        if (result[i][0] - result[i+1][0])**2 + (result[i][1] - result[i+1][1])**2 > loosen**2
          loosened.push result[i]
          loosened.push result[i+1] if i == result.size-2
          i +=1
        else
          loser = (result[i][1] - result[i+1][1] >= 0) ? i : i+1
          #puts "comparing #{result[i..i+1]}, loser is #{loser}"
          result.delete_at loser
          loosened.push result[i] if i == result.size-1
          #puts "deleting at #{loser}"
        end
      end
      result = loosened
    end
    result
  end


  def resample(sample_in)
    raise "Not a sampling 1D array" unless sample_in.is_a? Array
    raise "Expecting 1D array to be passed in" unless sample_in.all? Numeric
    sample = sample_in.sort # Avoid mutating the resample array
    
    update_info

    result = Spectrum.new
    result.name = @name + '-resampled'
    result.desc += "/#{sample.size} points"

    # Frequency value could be increasing or depending on unit
    x_polarity = (self[-1][0] - self[0][0] > 0 ) ? 1 : -1
    sample.reverse! if x_polarity == -1

    i = 0
    while (sampling_point = sample.shift)
      # Ugly catch for out of range points, throw out zero
      if sampling_point < self.spectral_range[0] || sampling_point > spectral_range[1]
        result.push [sampling_point, 0.0]
        next
      end

      # self[i][0] need to surpass sampling point to bracket it. Careful of rounding error
      while (i < self.size - 1) && ((sampling_point - self[i][0]) * x_polarity > 0.000001)
        i += 1
      end

      # Could be unnecessarily costly, but I can think of no better way at the moment
      if i == 0 
        interpolation = self[0][1]
      else
        interpolation = self[i-1][1] + (self[i][1] - self[i-1][1]) * (sampling_point - self[i-1][0]) / (self[i][0] - self[i-1][0])
      end
      result.push [sampling_point, interpolation]
    end

    result.update_info

    # sample array is sorted right so the right sequence will follow ^.<
    # result.reverse! if x_polarity == -1
    result
  end

  def *(input)
    if input.is_a? Spectrum
      sample = self.map{|pt| pt[0]}.union(input.map{|pt| pt[0]})
      self_resmpled_v = GSL::Vector.alloc(self.resample(sample).map {|pt| pt[1]})
      input_resmpled_v = GSL::Vector.alloc(input.resample(sample).map {|pt| pt[1]})
      self_resmpled_v * input_resmpled_v.col
    elsif input.is_a? Numeric
      self.each {|pt| pt[1] = pt[1].to_f * input}
    end
  end

  def /(input)
    raise "Not being devided by a number." unless input.is_a? Numeric
    self.each {|pt| pt[1] = pt[1].to_f / input}
  end

  def +(input)
    sample = self.map{|pt| pt[0]}.union(input.map{|pt| pt[0]})
    self_resampled = self.resample(sample)
    input_resmpled = input.resample(sample)
    raise "bang" unless self_resampled.size == input_resmpled.size
    self_resampled.each_index do |i|
      self_resampled[i][1] += input_resmpled[i][1]
    end
    self_resampled
  end

  def -(input)
    sample = self.map{|pt| pt[0]}.union(input.map{|pt| pt[0]})
    self_resampled = self.resample(sample)
    input_resmpled = input.resample(sample)
    raise "bang" unless self_resampled.size == input_resmpled.size
    self_resampled.each_index do |i|
      self_resampled[i][1] -= input_resmpled[i][1]
    end
    self_resampled
  end

  def uniform_resample(n)
    spacing = (@spectral_range[1] - @spectral_range[0]).to_f / n
    sample = (0..n-1).map{|i| @spectral_range[0] + (i+0.5) * spacing}
    self.resample sample
  end
end

def plot_spectra(spectra, options = {})
  raise "Not an array of spectra input." unless (spectra.is_a? Array) && (spectra.all? Spectrum)

  # Check if they align in x_units
  x_units = spectra.map {|spectrum| spectrum.units[0]}
  raise "Some spectra have different units!" unless x_units.all? {|unit| unit == x_units[0]}

  if options['outdir']
    plotdir = options['outdir']
  else
    plotdir = "plot-" + Time.now.strftime("%d%b-%H%M%S")
  end
  Dir.mkdir plotdir unless Dir.exist? plotdir

  plots = []
   plots += options['plotline_inject'] if options['plotline_inject']
  spectra.each_with_index do |spectrum, i|
    spectrum.write_tsv(plotdir + '/' + spectrum.name + '.tsv')
    plots.push "'#{plotdir}/#{spectrum.name}.tsv' with lines lt #{i+1}"
  end
  plotline = "plot " + plots.join(", \\\n")
  gplot = File.open plotdir + "/gplot", 'w'
  plot_headder = <<GPLOT_HEADER
  set terminal png size 800,600 lw 2
  set output '#{plotdir}/spect_plot.png'
  set xlabel '#{x_units[0]}'
  set ylabel 'intensity (cts)'
GPLOT_HEADER
  gplot.puts plot_headder
  gplot.puts plotline
  plot_replot = <<GPLOT_replot
  set terminal svg mouse enhanced standalone size 800,600 lw 2
  set output '#{plotdir}/spect_plot.svg'
  replot
GPLOT_replot
  gplot.puts options['extra_setup'] if options['extra_setup']
  gplot.puts plot_replot
  gplot.close
  system("gnuplot #{plotdir}/gplot")
end

# Quick 'n dirty func. to convert plot coord. to piezo coord.
def coord_conv(pl_scan_orig, orig_dim, map_dimension, coord)
  return [coord[0].to_f/map_dimension[0]*orig_dim[0]+pl_scan_orig[0], coord[1].to_f/map_dimension[1]*orig_dim[1]+pl_scan_orig[1]]
end

# Data form: [x1 y1-1 y2-1] [x2 y1-2 y2-2 ...]
def quick_plot(data)
  Dir.mkdir 'output' unless Dir.exists? 'output'
  raise "Some entries in data are different in length" unless data.all? {|line| line.size == data[0].size}
  data_fname = "data_#{Time.now.strftime("%d%b%Y-%H%M%S")}"
  data_fout = File.open "output/#{data_fname}.tsv", 'w'
  data.each { |line| data_fout.puts line.join("\t")}
  data_fout.close

  plotlines = []
  data[0].each_with_index do |column, i|
    # Assume for now no headder line
    plotlines.push "u 1:($#{i+1}) t '#{i+1}'"
  end
      
  plot_line = "plot 'output/#{data_fname}.tsv'" + plotlines.join(", \\\n'' ")
  plot_headder = <<GPLOT_HEADER
  set terminal png size 800,600 lw 2
  set output 'output/#{data_fname}.png'
GPLOT_HEADER
  plot_replot = <<GPLOT_replot
  set terminal svg mouse enhanced standalone size 800,600 lw 2
  set output 'output/#{data_fname}.svg'
  replot
GPLOT_replot

  gplot_out = File.new "output/#{data_fname}.gplot", 'w'
  gplot_out.puts plot_headder
  gplot_out.puts plot_line
  gplot_out.puts plot_replot
  gplot_out.close
  `gnuplot 'output/#{data_fname}.gplot'`
  data_fname
end

def matrix_write(matrix, path)
  raise "Some entries in data are different in length" unless matrix.all? {|line| line.size == matrix[0].size}
  matrix_out = File.open path, 'w'
  matrix.each do |line|
    matrix_out.puts line.join "\t" 
  end
  matrix_out.close
end

def gaussian(sample, pos, width, height)
  basis = Spectrum.new
  basis.name = "#{pos}-#{width}-#{height}"
  sample.each do |x|
    basis.push [x, Math.exp(-(((x - pos) / width)**2)) * height]
  end
  basis
end

def lorentzian(sample, pos, width, height)
  basis = Spectrum.new
  basis.name = "lorenzian-#{pos}-#{width}-#{height}"
  sample.each do |x|
    basis.push [x, height.to_f / (1+ (2.0 * (x - pos) / width)**2)]
  end
  basis
end