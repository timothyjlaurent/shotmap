# Invoke %  R  --slave  --args  class.id  outdir  out.file.stem  metadata.tab <  calculate_diversity.R

require(vegan)
require(ggplot2)
require(reshape2)

options(error=traceback)
options(error=recover)

Args              <- commandArgs()
samp.abund.map    <- Args[4]
metadata.tab      <- Args[6]
sample.stem       <- Args[7]
compare.stem      <- Args[8]

samp.abund.map <- "/mnt/data/work/pollardlab/sharpton/MRC_ffdb/projects/SFams_english_channel_L4/90/output/Abundance_Map_cid_54_aid_1.tab"
metadata.tab <- "/mnt/data/work/pollardlab/sharpton/MRC_ffdb/projects/SFams_english_channel_L4/90/output/sample_metadata.tab"
sample.stem <- "/mnt/data/work/pollardlab/sharpton/MRC_ffdb/projects/SFams_english_channel_L4/90/output/Sample_Diversity_cid_54_aid_1"
compare.stem <- "/mnt/data/work/pollardlab/sharpton/MRC_ffdb/projects/SFams_english_channel_L4/90/output/Compare_samples_cid_54_aid_1"


print.log = 0

####Good's coverage
####takes matrix of family abundances by sample
goods.coverage <- function( abunds.map ) {  
  count = apply( abunds.map, 1, sum )
  tmap  = t(abunds.map)
  singletons = apply( tmap, 2, function(df){length(subset(df, df <= 1 & df > 0 ) ) } )
  coverage   = 1 - ( singletons / count )
  return( coverage )
}

###Autodetect metadata variable type
###takes a list of values and determines if likely discrete or continuous. May not be perfect!
autodetect <- function( val.list ) {
  cont.thresh = 0.2 #what is min number of unique vals that constitutes a continuous list?
  type = NULL
  ##if any item matches a character, label as discrete
  if( length(which(grepl( "[a-z|A-Z]", val.list))) > 0 ){
    type = "discrete"
    return( type )
  }
  ##see if list of numbers looks like is has many or few types, using cont.thresh as a guide
  rel.uniqs <- length( unique( val.list ) ) / length( val.list ) #relative number of unique values
  if( rel.uniqs < cont.thresh ){
    type = "discrete"
  }
  else{
    type = "continuous"
  } 
  if( is.null( type ) ){
    print( paste("Could not autodetect value types for", val.list, sep=" ") );
    exit();
  }
  return( type )
}

####get the metadata
print( "Grabbing metadata..." )
meta       <- read.table( file=metadata.tab, header=TRUE, check.names=FALSE )
meta.names <- colnames( meta )

###get family abundances by samples
print( "Grabbing family abundance data..." )
abund.df <- read.table( file=samp.abund.map, header=TRUE, check.names=FALSE )
abund.map  <- acast(abund.df, SAMPLE.ID~FAMILY.ID, value.var="ABUNDANCE" ) #could try to do all work in the .df object instead, enables ggplot
samples    <- rownames(abund.map)
famids     <- colnames(abund.map)

### DO WE NEED THIS
###get family relative abundances by samples
### we need this in case we calc abundance as family coverage, where
### normalization is a function of total target length
print( "Grabbing relative abundance data..." )
ra.map  <- acast(ra.map, SAMPLE.ID~FAMILY.ID, value.var="REL.ABUND" ) #could try to do all work in .df object, enables ggplot

###calculate various types of diversity
print( "Calculating Shannon Entropy..." )
shannon    <- diversity(abund.map)
print( "Calculating Richness..." )
richness   <- specnumber(abund.map)
print( "Calculating Good's Coverage..." )
goods      <- goods.coverage(abund.map)

div.map    <- cbind( shannon, richness, goods )
div.file   <- paste( sample.stem, ".tab", sep="" )
print( paste( "Producing diversity map file here: ", div.file, sep="") )
write.table( div.map, file = div.file )

###Make per-Sample Rank Abundance Plots
print( "Plotting rank abundance curves..." )
for( i in 1:dim(abund.map)[1] ){
  samp           <- rownames(abund.map)[i]
  data           <- abund.map[samp,]
  ra.data        <- ra.map[samp,]
  names(data)    <- c( "ABUNDANCE" )
  names(ra.data) <- c( "RELATIVE_ABUNDANCE" )  
  ##sample RA
  file <- paste( sample.stem, "_sample_", samp, "_RA.pdf", sep="" )
  pdf( file )
  plot( 1:length(sort(ra.data[1,] )), rev(sort( ra.data[1,]) ), type="l",
       xlab = "Family Rank",
       ylab = "Relative Abundance",
       main = paste( "Relative Abundance of Sample ", samp, sep="" )
       )
  dev.off()
  ##sample RA (log scale)
  if( print.log ){
    file <- paste( sample.stem, "_sample_", samp, "_RA_log.pdf", sep="" )
    pdf( file )
    plot( 1:length(sort(ra.data[1,] )), rev( sort( log(ra.data[1,]) ) ), type="l",
         xlab = "Family Rank",
         ylab = "Relative Abundanc (Log)",
         main = paste( "Relative Abundance of Sample ", samp, " Log Scale", sep="" )
         )
    dev.off()
  }
}

###Plot all sample relative abundances in single image
file <- paste( sample.stem, "_all_samples_RA.pdf", sep="" )
pdf( file )
for( i in 1:dim(abund.map)[1] ){
  samp           <- rownames(abund.map)[i]
  data           <- abund.map[samp,]
  ra.data        <- ra.map[samp,]
  names(data)    <- c( "ABUNDANCE" )
  names(ra.data) <- c( "RELATIVE_ABUNDANCE" )  
  if( i == 1 ){
    plot( 1:length(sort(ra.data[1,] )), rev(sort( ra.data[1,]) ), type="l",
         xlab = "Family Rank",
         ylab = "Relative Abundance",
         main = paste( "Relative Abundance Distributions", sep="" )
         )
  } else{
    lines( 1:length(sort(ra.data[1,] )), rev(sort( ra.data[1,]) ) )
  }
}
dev.off()

###Plot all log-corrected sample relative abundances in single image
if( print.log ){
  print( "Plotting log-space rank abundance curve..." )
  file <- paste( sample.stem, "_all_samples_RA_log.pdf", sep="" )
  pdf( file )
  for( i in 1:dim(abund.map)[1] ){
    samp           <- rownames(abund.map)[i]
    data           <- abund.map[samp,]
    ra.data        <- ra.map[samp,]
    names(data)    <- c( "ABUNDANCE" )
    names(ra.data) <- c( "RELATIVE_ABUNDANCE" )  
    if( i == 1 ){
      plot( 1:length(sort(ra.data[1,] )), rev(sort( log( ra.data[1,]) ) ), type="l",
           xlab = "Family Rank",
           ylab = "Relative Abundance",
           main = paste( "Relative Abundance Distributions", sep="" )
           )
    } else{
      lines( 1:length(sort(ra.data[1,] )), rev(sort( log( ra.data[1,]) ) ) )
    }
  }
  dev.off()
}

###Plot per sample diversity statistics

###tmp:
###div.map[2,3] <- 0
###tmp.map <- cbind( as.data.frame( as.integer(rownames(div.map))), div.map ) 
###colnames(tmp.map) <- c( "SAMPLE.ID", colnames(div.map) )
###tmp.map$SAMPLE.ORDERED <- factor( tmp.map$SAMPLE.ID, sort( tmp.map$SAMPLE.ID) )
print( "Plotting diversity statistics" )
for( b in 1:length( colnames(div.map) ) ){
  div.type <- colnames(div.map)[b]
  if( div.type == "SAMPLE.ID" ){
    next
  }
  if( div.type == "shannon" ){
    ylabel <- "Shannon Entropy"
  }
  if( div.type == "richness" ){
    ylabel <- "Richness"
  }
  if( div.type == "goods" ){
    ylabel <- "Good's Coverage"
  }
  ggplot( tmp.map, aes_string(  x="SAMPLE.ORDERED", y= div.type ) ) +
    geom_bar( stat="identity" ) +
      labs( title = paste( ylabel, "across samples", sep="" ) ) +
        xlab( "Sample ID" ) +
          ylab( ylabel )
  file <- paste( sample.stem, "-", div.type, ".pdf", sep="" )
  print(file)
  ggsave( filename = file, plot = last_plot() )
}

###Can only do the below if metadata fields are provided


###merge metadata with diversity data for future plotting
if( exists( meta ) ){
  meta.div   <- merge( tmp.map, meta, by = "SAMPLE.ID" )
###Compare diversity statistics between metadata groups
  for( b in 1:length( meta.names ) ){
    for( d in 1:length( colnames(div.map) ) ){
      div.type  <- colnames(div.map)[d]
      meta.type <- meta.names[b]
      if( meta.type == "SAMPLE.ID" | meta.type == "SAMPLE.ALT.ID" ){
        next;
      }
      if( autodetect( meta[,meta.type] ) == "continuous" ){
        next
      }
      ggplot( meta.div, aes_string( x = meta.type, y=div.type ) ) +
        geom_boxplot() + #if color: geom_boxplot(aes(fill = COLNAME) )
          labs( title = paste( div.type, " by ", meta.names[b], sep="" ) ) +
            xlab( meta.type ) +
              ylab( div.type )
      file <- paste( sample.stem, "-", meta.type, "-", div.type, "-boxes.pdf", sep="" )
      print(file)
      ggsave( filename = file, plot = last_plot() )
    }
  }
###build scatter plots, grouping my metadata fields. Not always informative (e.g., when field is discrete)
  for( b in 1:length( meta.names ) ){
    for( d in 1:length( colnames(div.map) ) ){
      div.type  <- colnames(div.map)[d]
      meta.type <- meta.names[b]
      if( meta.type == "SAMPLE.ID" | meta.type == "SAMPLE.ALT.ID" ){
        next;
      }
      if( autodetect( meta[,meta.type] ) == "discrete" ){
        next
      }
      ggplot( meta.div, aes_string( x = meta.type, y=div.type ) ) +
        geom_point( ) + #if color: geom_point(aes(fill = COLNAME) )
          labs( title = paste( div.type, " by ", meta.names[b], sep="" ) ) +
            xlab( meta.type ) +
              ylab( div.type )
      file <- paste( sample.stem, "-", meta.type, "-", div.type, "-scatter.pdf", sep="" )
      print(file)
      ggsave( filename = file, plot = last_plot() )
    }
  }
###build line plots between types
  for( b in 1:length( meta.names ) ){
    for( d in 1:length( colnames(div.map) ) ){
      div.type  <- colnames(div.map)[d]
      meta.type <- meta.names[b]
      if( meta.type == "SAMPLE.ID" | meta.type == "SAMPLE.ALT.ID" ){
        next;
      }
      if( autodetect( meta[,meta.type] ) == "continuous" ){
        next
      }
      ggplot( meta.div, aes_string( x = meta.type, y=div.type ) ) +
        geom_line() + #if color: geom_line(aes(fill = COLNAME) )
          labs( title = paste( div.type, " by ", meta.names[b], sep="" ) ) +
            xlab( meta.type ) +
              ylab( div.type )
      file <- paste( sample.stem, "-", meta.type, "-", div.type, "-scatter.pdf", sep="" )
      print(file)
      ggsave( filename = file, plot = last_plot() )
    }
  }
}
