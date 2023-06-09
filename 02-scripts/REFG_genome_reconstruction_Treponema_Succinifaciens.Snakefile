################################################################################
# Project: Training project
# Part: Geneome Reconstruction
# Step: Reconstruction 
#
### NOT COMPLETE########
#
# Dependent on:
#   - PREP_remove_hostDNA.Snakefile
#   - COMP_Kraken2_Bracken.Snakefile
#
# Frederik Lutz
################################################################################

import os

import pandas as pd

if not os.path.isdir("snakemake_tmp"):
    os.makedirs("snakemake_tmp")

os.environ["OPENBLAS_NUM_THREADS"] = '1'
os.environ["OMP_NUM_THREADS"] = '1'

#### SAMPLES ###################################################################
SAMPLES, = glob_wildcards("03-data/processed_data/{sample}_1.fastq.gz")
################################################################################

GENOME_URLS = {'Treponema':'https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/195/275/GCF_000195275.1_ASM19527v1/GCF_000195275.1_ASM19527v1_genomic.fna.gz'}

wildcard_constraints:
    sample = "[ES]RS[0-9]+"

rule all:
    input:
        expand("04-analysis/refgenome_reconst/{sample}.freebayes_loose.fasta.gz", sample=SAMPLES),
        expand("04-analysis/refgenome_reconst/{sample}.freebayes_conserv.fasta", sample=SAMPLES),

#### Prepare sequencing data ###################################################

rule decompress_fasta:
    output:
        temp("tmp/refgenome_reconst/{genome}.fna")
    message: "Decompress the FastA file: {wildcards.genome}"
    params:
        url = lambda wildcards: GENOME_URLS[wildcards.genome]
    shell:
        "wget -O - {params.url} | gunzip > {output}"

rule bgzip_tabix:
    input:
        "tmp/refgenome_reconst/{genome}.fna"
    output:
        fasta = "tmp/refgenome_reconst/{genome}.fna.gz",
        fai = "tmp/refgenome_reconst/{genome}.fna.gz.fai"
    message: "Compress the FastA file: {wildcards.genome}"
    conda: "ENVS_samtools.yaml"
    resources:
        mem = 4,
        cores = 1
    threads: 1
    shell:
        """
        bgzip {input}
        samtools faidx {output.fasta}
        """

rule bowtie2_index:
    input:
        fasta = "tmp/refgenome_reconst/{genome}.fna.gz",
        fai = "tmp/refgenome_reconst/{genome}.fna.gz.fai"
    output:
        "tmp/refgenome_reconst/{genome}.1.bt2"
    message: "Index for BowTie2 alignment: {wildcards.genome}"
    conda: "ENVS_bowtie2.yaml"
    resources:
        mem = 4,
        cores = 1
    params:
        prefix = "tmp/refgenome_reconst/{genome}"
    threads: 1
    shell:
        """
        bowtie2-build --threads {threads} \
                {input.fasta} {params.prefix}
        """

################################################################################

#### Align data ################################################################

rule bowtie2:
    input:
        "tmp/refgenome_reconst/TSuccinifaciens.1.bt2"  
    output:
        pipe("tmp/refgenome_reconst/{sample}.sam")
    message: "Align sequences against reference genomes using BowTie2: {wildcards.sample}"
    conda: "ENVS_bowtie2.yaml"
    resources:
        mem = 8,
        cores = 8
    params:
        index =  "tmp/refgenome_reconst/TSuccinifaciens",
        pe1 = "03-data/processed_data/{sample}_1.fastq.gz",
        pe2 = "03-data/processed_data/{sample}_2.fastq.gz"
    threads: 8
    shell:
        """
        bowtie2 -p {threads} --very-sensitive -x {params.index} \
            -1 {params.pe1} -2 {params.pe2} > {output}
        """

rule sam2bam:
    input:
        "tmp/refgenome_reconst/{sample}.sam"
    output:
        pipe("tmp/refgenome_reconst/{sample}.bam")
    message: "Convert SAM to BAM format: {wildcards.sample}"
    conda: "ENVS_samtools.yaml"
    resources:
        mem = 2,
        cores = 0
    shell:
        "samtools view -Su -e '!flag.unmap || !flag.munmap' {input} > {output}"

rule samtools_fixmate:
    input:
        "tmp/refgenome_reconst/{sample}.bam"
    output:
        pipe("tmp/refgenome_reconst/{sample}.fixmate.bam")
    message: "Fix mate flags: {wildcards.sample}"
    conda: "ENVS_samtools.yaml"
    resources:
        mem = 2,
        cores = 0
    shell:
        "samtools fixmate -mu {input} {output}"

rule samtools_sort:
    input:
        "tmp/refgenome_reconst/{sample}.fixmate.bam"
    output:
        pipe("tmp/refgenome_reconst/{sample}.sorted.bam")
    message: "Sort BAM file by coordinate: {wildcards.sample}"
    conda: "ENVS_samtools.yaml"
    resources:
        mem = 2,
        cores = 0
    shell:
        "samtools sort -u -o {output} {input}"

rule samtools_calmd:
    input:
        "tmp/refgenome_reconst/{sample}.sorted.bam"
    output:
        "04-analysis/refgenome_reconst/{sample}.calmd.bam"
    message: "Calculate the MD tag: {wildcards.sample}"
    conda: "ENVS_samtools.yaml"
    resources:
        mem = 8,
        cores = 1
    params:
        fa = "tmp/refgenome_reconst/TSuccinifaciens.fna.gz" 
    shell:
        "samtools calmd -b {input} {params.fa} > {output}"

rule samtools_index:
    input:
        "04-analysis/refgenome_reconst/{sample}.calmd.bam"
    output:
        "04-analysis/refgenome_reconst/{sample}.calmd.bam.bai"
    message: "Index the BAM file: {wildcards.sample}"
    conda: "ENVS_samtools.yaml"
    resources:
        mem = 4,
        cores = 1
    shell:
        "samtools index {input}"

################################################################################

#### Prepare reference for genotyping with freeBayes ###########################

rule uncompress_reffasta:
    
    input: 
    output:
        temp("tmp/genome_reconst/{genome}.fasta")
    message: "Decompress the FastA file of the reference genome: {wildcards.genome}"
    resources:
        mem = 4,
        cores = 1

    shell:
        """
        gunzip -c {params.fasta} > {output}
        """

rule faidx_reffasta:
    input:
        "tmp/genome_reconst/{genome}.fasta"
    output:
        temp("tmp/genome_reconst/{genome}.fasta.fai")
    message: "Generate FastA index for the reference genome: {wildcards.genome}"
    conda: "ENVS_samtools.yaml"
    resources:
        mem = 4,
        cores = 1
    shell:
        """
        samtools faidx {input}
        """

################################################################################

#### Genotyping using freeBayes ################################################

rule freebayes:
    input:
        fa = "tmp/genome_reconst/TSuccinifaciens.fasta" ,
        fai = "tmp/genome_reconst/TSuccinifaciens.fasta.fai" 
        bam = "04-analysis/refgenome_reconst_tsuccinifaciens/{sample}.calmd.bam",
        bai = "04-analysis/refgenome_reconst_tsuccinifaciens/{sample}.calmd.bam.bai",

    output:
        pipe("tmp/genome_reconst/{sample}.vcf")
    message: "Genotype the contigs using freeBayes in parallel mode: {wildcards.sample}"
    conda: "ENVS_freebayes.yaml"
    group: "freebayes"
    resources:
        mem = 8,
        cores = 1
    params:
        bam = "04-analysis/genome_reconst/{sample}.calmd.bam"
    threads: 1
    shell:
        """
        freebayes -f {input.fa} \
            --report-monomorphic \
            -C 1 -F 0.05 -p 1 \
            --haplotype-length 0 \
            -q 30 -m 20 {params.bam} > {output}
        """

rule compress_vcf:
    input:
        "tmp/genome_reconst/{sample}.vcf"
    output:
        "04-analysis/refgenome_reconst/{sample}.freebayes.vcf.gz"
    message: "Compress the VCF file produced by freebayes: {wildcards.sample}"
    conda: "ENVS_samtools.yaml"
    group: "freebayes"
    resources:
        mem = 4,
        cores = 1
    threads: 1
    shell:
        """
        bgzip -c {input} > {output}
        """

rule bcftools_filter:
    input:
        "04-analysis/refgenome_reconst/{sample}.freebayes.vcf.gz"
    output:
        vcf = "04-analysis/refgenome_reconst/{sample}.filter.vcf.gz",
        tbi = "04-analysis/refgenome_reconst/{sample}.filter.vcf.gz.tbi"
    message: "Discard low-quality differences between MEGAHIT and freebayes consensus: {wildcards.sample}"
    conda: "ENVS_bcftools.yaml"
    resources:
        mem = 4,
        cores = 1
    shell:
        """
        bcftools view \
            -v snps,mnps \
            -i 'QUAL >= 30 || (QUAL >= 20 && INFO/AO >= 3)' {input} | \
        bgzip > {output.vcf}
        bcftools index -t {output.vcf}
        """

################################################################################

#### Majority calling ##########################################################



#### Call consensus ############################################################

rule bcftools_consensus:
    input:
        vcf = "04-analysis/refgenome_reconst/{sample}.filter.vcf.gz",
        tbi = "04-analysis/refgenome_reconst/{sample}.filter.vcf.gz.tbi"
    output:
        "04-analysis/refgenome_reconst/{sample}.freebayes_loose.fasta.gz"
    message: "Correct the consensus sequence of the contigs: {wildcards.sample}"
    conda: "ENVS_bcftools.yaml"
    resources:
        mem = 8,
        cores = 2
    params:
        fasta = "tmp/genome_reconst/TSuccinifaciens.fna.gz" 
    threads: 2
    shell:
        """
        cat {params.fasta} | bcftools consensus {input.vcf} | bgzip > {output}
        """

rule vcf2fasta_freebayes:
    input:
        "04-analysis/refgenome_reconst/{sample}.freebayes.vcf.gz"
    output:
        "04-analysis/refgenome_reconst_tsuccinifaciens/{sample}.freebayes_conserv.fasta"
    message: "Convert the freeBayes VCF file into FastA file: {wildcards.sample}"
    conda: "ENVS_vcf2fasta.yaml"
    resources:
        mem = 8,
        cores = 1
    params:
        fasta = "tmp/genome_reconst/TSuccinifaciens.fna.gz"  
    shell:
        """
        02-scripts/pyscripts/vcf2fasta.py \
            -i {input} \
            -o {output} \
            -r {params.fasta} \
            --minqual_fallback 20 --mincov_fallback 3
        """

################################################################################
