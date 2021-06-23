/*
========================================================================================
    MAPPING
========================================================================================
*/

params.seqkit_split2_options     = [:]
params.bwamem1_mem_options       = [:]
params.bwamem1_mem_tumor_options = [:]
params.bwamem2_mem_options       = [:]
params.bwamem2_mem_tumor_options = [:]
// params.merge_bam_options         = [:]
// params.qualimap_bamqc_options    = [:]
// params.samtools_index_options    = [:]
// params.samtools_stats_options    = [:]

include { SEQKIT_SPLIT2 }                from '../../modules/nf-core/software/seqkit/split2/main.nf' addParams(options: params.seqkit_split2_options)
include { BWA_MEM as BWAMEM1_MEM }       from '../../modules/nf-core/software/bwa/mem/main'          addParams(options: params.bwamem1_mem_options)
include { BWA_MEM as BWAMEM1_MEM_T }     from '../../modules/nf-core/software/bwa/mem/main'          addParams(options: params.bwamem1_mem_tumor_options)
include { BWAMEM2_MEM }                  from '../../modules/nf-core/software/bwamem2/mem/main'      addParams(options: params.bwamem2_mem_options)
include { BWAMEM2_MEM as BWAMEM2_MEM_T } from '../../modules/nf-core/software/bwamem2/mem/main'      addParams(options: params.bwamem2_mem_tumor_options)
//include { SAMTOOLS_MERGE }               from '../../modules/nf-core/software/samtools/merge/main'   addParams(options: params.merge_bam_options)
//include { QUALIMAP_BAMQC }               from '../../modules/nf-core/software/qualimap/bamqc/main'   addParams(options: params.qualimap_bamqc_options)
//include { SAMTOOLS_INDEX }               from '../../modules/nf-core/software/samtools/index/main'   addParams(options: params.samtools_index_options)
//include { SAMTOOLS_STATS }               from '../../modules/nf-core/software/samtools/stats/main'   addParams(options: params.samtools_stats_options)

workflow MAPPING {
    take:
        //skip_bamqc      // boolean: true/false
        //skip_samtools   // boolean: true/false
        aligner         // string:  [mandatory] "bwa-mem" or "bwa-mem2"
        bwa             // channel: [mandatory] bwa
        fai             // channel: [mandatory] fai
        fasta           // channel: [mandatory] fasta
        reads_input     // channel: [mandatory] meta, reads_input

    main:

    bam_mapped_index = Channel.empty()
    bam_reports      = Channel.empty()


    if(params.split_fastq > 1){
        reads_input_split = SEQKIT_SPLIT2(reads_input).reads.map{
                key, reads ->
                    //TODO maybe this can be replaced by a regex to include part_001 etc.

                    //sorts list of split fq files by :
                    //[R1.part_001, R2.part_001, R1.part_002, R2.part_002,R1.part_003, R2.part_003,...]
                    //TODO: determine whether it is possible to have an uneven number of parts, so remainder: true woud need to be used, I guess this could be possible for unfiltered reads, reads that don't have pairs etc.
                    return [key, reads.sort{ a,b -> a.getName().tokenize('.')[ a.getName().tokenize('.').size() - 3] <=> b.getName().tokenize('.')[ b.getName().tokenize('.').size() - 3]}
                                            .collate(2)]
            }.transpose()
    }else{
        reads_input_split = reads_input
    }

    //reads_input_split.dump(tag:'Split reads')

    // If meta.status is 1, then sample is tumor
    // else, (even is no meta.status exist) sample is normal
    reads_input_split.branch{
            tumor:  it[0].status == 1
            normal: true
        }.set{ reads_input_status }

    bam_bwamem1 = Channel.empty()
    bam_bwamem2 = Channel.empty()

    if (aligner == "bwa-mem") {
        BWAMEM1_MEM(reads_input_status.normal, bwa)
        bam_bwamem1_n = BWAMEM1_MEM.out.bam

        BWAMEM1_MEM_T(reads_input_status.tumor, bwa)
        bam_bwamem1_t = BWAMEM1_MEM_T.out.bam

        bam_bwamem1 = bam_bwamem1_n.mix(bam_bwamem1_t)
    } else {
        BWAMEM2_MEM(reads_input_status.normal, bwa)
        bam_bwamem2_n = BWAMEM2_MEM.out.bam

        BWAMEM2_MEM_T(reads_input_status.tumor, bwa)
        bam_bwamem2_t = BWAMEM2_MEM_T.out.bam

        bam_bwamem2 = bam_bwamem2_n.mix(bam_bwamem2_t)
    }
    //'Mix' here prevents that parts of the channel are already run through MarkDuplicates. mIght actually not be 'mix' but 'groupTuple' that is the problem
    bam_bwa = bam_bwamem1.mix(bam_bwamem2)
    //Still the problem remains now after splitting, how to join the splits in a non-blocking way.

    //Moved this to whereever we merge
    bam_bwa.map{ meta, bam ->
        meta.remove('read_group')
        meta.id = meta.sample
        def groupKey = groupKey(meta, meta.numLanes * params.split_fastq)
        tuple(groupKey, bam)
        [meta, bam]
    }.dump(tag:'groupkey').groupTuple()
    .set{bam_mapped}
    bam_mapped.dump(tag:'mapping')

    //Moved this to whereever we merge
    //.branch{
    //     single:   it[1].size() == 1
    //     multiple: it[1].size() > 1
    // }.set{ bam_bwa_to_sort }

    // STEP 1.5: MERGING AND INDEXING BAM FROM MULTIPLE LANES // MarkDuplicates can take care of this

    //SAMTOOLS_MERGE(bam_bwa_to_sort.multiple)
    //bam_mapped = bam_bwa_to_sort.single.mix(SAMTOOLS_MERGE.out.merged_bam)

    //SAMTOOLS_INDEX(bam_mapped)
    //bam_mapped_index = bam_mapped.join(SAMTOOLS_INDEX.out.bai)

    // qualimap_bamqc = Channel.empty()
    // samtools_stats = Channel.empty()

    // if (!skip_bamqc) {
    //     QUALIMAP_BAMQC(bam_mapped, target_bed, params.target_bed)
    //     qualimap_bamqc = QUALIMAP_BAMQC.out
    // }

    // if (!skip_samtools) {
    //     SAMTOOLS_STATS(bam_mapped_index)
    //     samtools_stats = SAMTOOLS_STATS.out.stats
    // }

    // bam_reports = samtools_stats.mix(qualimap_bamqc)
    emit:
        bam = bam_mapped //_index
        //bam_mapped_normal = bam_mapped_normal//qc  = bam_reports
}
